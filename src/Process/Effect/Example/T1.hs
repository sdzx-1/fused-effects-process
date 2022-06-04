{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Effect.Example.T1 where

import Control.Algebra (Algebra (..), type (:+:) (..))
import Control.Carrier.Error.Either
  ( Error,
    Has,
    runError,
    throwError,
  )
import Control.Carrier.Lift (Lift (..), sendM)
import Control.Carrier.Metric.Pure (runMetric)
import Control.Carrier.Reader
  ( Reader,
    ask,
    runReader,
  )
import Control.Carrier.State.Strict
  ( State,
    get,
    modify,
    runState,
  )
import Control.Effect.Metric
  ( Default (..),
    K (..),
    Metric,
    NameVector (..),
    Vlength (..),
    getAll,
    inc,
  )
import Control.Monad (void, when)
import Control.Monad.Class.MonadFork (MonadFork (forkIO), MonadThread (labelThread))
import Control.Monad.Class.MonadSTM (MonadSTM)
import Control.Monad.Class.MonadSay (MonadSay (..))
import Control.Monad.Class.MonadTime (MonadTime (..), diffUTCTime)
import Control.Monad.Class.MonadTimer
  ( MonadDelay (..),
    MonadTimer,
  )
import Control.Monad.IOSim
  ( ppEvents,
    runSimTrace,
    traceEvents,
  )
import Data.Kind
  ( Type,
  )
import Data.Time (UTCTime)
import Process.Effect.HasMessageChan (HasMessageChan, runServer)
import Process.Effect.HasServer
  ( HasServer,
    call,
    cast,
    runWithServer,
  )
import Process.Effect.TH (mkSigAndClass)
import Process.Effect.Type (RespVal, ToList, ToSig (..))
import Process.Effect.Utils
  ( forever,
    newMessageChan,
    withMessageChan,
    withResp,
  )
import Process.TH (fromList, mkMetric)

data C (n :: Type -> Type) where
  C :: RespVal n Int %1 -> C n

data D (n :: Type -> Type) where
  D :: Int -> D n

data Status (n :: Type -> Type) where
  Status :: RespVal n (Int, [(String, Int)]) %1 -> Status n

mkSigAndClass
  "SigC"
  [ ''C,
    ''D,
    ''Status
  ]

mkMetric
  "Sc"
  [ "all_all",
    "all_c",
    "all_d"
  ]

client ::
  forall n sig m.
  ( MonadSay n,
    Has (Error ()) sig m,
    HasServer "s" SigC '[C, D, Status] n sig m
  ) =>
  m ()
client = forever $ do
  sts <- call @"s" Status
  sendM @n $ say $ show sts
  val <- call @"s" C
  when (val >= 20) $ throwError ()
  cast @"s" $ D val

server ::
  forall n sig m.
  ( MonadSay n,
    MonadSTM n,
    MonadTime n,
    MonadDelay n,
    HasMessageChan "s" SigC n sig m,
    Has
      ( Metric Sc
          :+: Reader UTCTime
          :+: State Int
      )
      sig
      m
  ) =>
  m ()
server = forever $ do
  inc all_all
  withMessageChan @"s" $ \case
    SigC1 (C resp) -> withResp resp $ do
      inc all_c
      sendM @n $ threadDelay 0.1
      get @Int
    SigC2 (D i) -> do
      inc all_d
      modify (+ i)
      val <- get @Int
      startTime <- ask
      time <- sendM @n $ getCurrentTime
      sendM @n $ say $ show (val, time `diffUTCTime` startTime)
    SigC3 (Status resp) -> withResp resp $ do
      ni <- get @Int
      ms <- getAll @Sc
      pure (ni, ms)

runval ::
  forall n.
  ( MonadSay n,
    MonadSTM n,
    MonadFork n,
    MonadDelay n,
    MonadTimer n,
    MonadTime n,
    Algebra (Lift n) n
  ) =>
  n ()
runval = do
  s <- newMessageChan @n @SigC
  time <- getCurrentTime

  tid <-
    forkIO
      . void
      . runReader time
      . runMetric @Sc
      . runState @Int 1
      . runServer @"s" s
      $ server

  labelThread tid "server"

  void
    . runWithServer @"s" s
    . runError @()
    $ client

runval1 :: IO ()
runval1 = runval

runval2 :: IO ()
runval2 =
  writeFile "event.log"
    . ppEvents
    . traceEvents
    . runSimTrace
    $ runval

-- >>> runval2
