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

module Control.Effect.Texample where

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
import Control.Effect.T
  ( HasMessageChan,
    HasServer,
    RespVal,
    ToList,
    ToSig (..),
    call,
    cast,
    forever,
    newMessageChan,
    runServer,
    runWithServer,
    withMessageChan,
    withResp,
  )
import Control.Effect.TH (mkSigAndClass)
import Control.Monad (void, when)
import Control.Monad.Class.MonadFork (MonadFork (forkIO))
import Control.Monad.Class.MonadSTM
import Control.Monad.Class.MonadSay (MonadSay (..))
import Control.Monad.Class.MonadTime (MonadTime (..), diffUTCTime)
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim
  ( runSimTrace,
    selectTraceEventsSay,
  )
import Data.Kind
  ( Type,
  )
import Data.Time (UTCTime)
import Process.TH (fromList, mkMetric)

--------------------------- example

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
    Has (Lift n :+: Error ()) sig m,
    HasServer "s" SigC '[C, D, Status] n sig m
  ) =>
  m ()
client = forever $ do
  sts <- call @"s" Status
  sendM @n $ say $ show sts
  val <- call @"s" C
  when (val >= 1000) $ throwError ()
  cast @"s" $ D val

server ::
  forall n sig m.
  ( MonadSay n,
    MonadSTM n,
    MonadTime n,
    MonadDelay n,
    HasMessageChan "s" SigC n sig m,
    Has
      ( Lift n
          :+: Metric Sc
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
      sendM @n $ threadDelay 0.3
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

  forkIO
    . void
    . runReader time
    . runMetric @Sc
    . runState @Int 1
    . runServer @"s" s
    $ server

  void
    . runWithServer @"s" s
    . runError @()
    $ client

runval1 :: IO ()
runval1 = runval

runval2 :: [String]
runval2 = selectTraceEventsSay $ runSimTrace runval

-- >>> runval2
-- ["(1,[(\"all_all\",1),(\"all_c\",0),(\"all_d\",0)])","(2,0.3s)","(2,[(\"all_all\",4),(\"all_c\",1),(\"all_d\",1)])","(4,0.6s)","(4,[(\"all_all\",7),(\"all_c\",2),(\"all_d\",2)])","(8,0.9s)","(8,[(\"all_all\",10),(\"all_c\",3),(\"all_d\",3)])","(16,1.2s)","(16,[(\"all_all\",13),(\"all_c\",4),(\"all_d\",4)])","(32,1.5s)","(32,[(\"all_all\",16),(\"all_c\",5),(\"all_d\",5)])","(64,1.8s)","(64,[(\"all_all\",19),(\"all_c\",6),(\"all_d\",6)])","(128,2.1s)","(128,[(\"all_all\",22),(\"all_c\",7),(\"all_d\",7)])","(256,2.4s)","(256,[(\"all_all\",25),(\"all_c\",8),(\"all_d\",8)])","(512,2.7s)","(512,[(\"all_all\",28),(\"all_c\",9),(\"all_d\",9)])","(1024,3s)","(1024,[(\"all_all\",31),(\"all_c\",10),(\"all_d\",10)])"]
