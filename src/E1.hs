{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module E1 where

import Control.Algebra
import Control.Carrier.Reader
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad
import Control.Monad.IO.Class
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Time
import Process.HasServer
import Process.HasWorkGroup
import Process.TH
import Process.Type
import Process.Util

-------------------------------------exception or terminate

data ProcessR where
  ProcessR :: Int -> (Either SomeException ()) -> ProcessR

mkSigAndClass "SigException" [''ProcessR]

data EotConfig = EotConfig
  { einterval :: Int,
    etMap :: TVar (IntMap (MVar Result))
  }

eotProcess ::
  ( HasServer "et" SigException '[ProcessR] sig m,
    Has (Reader EotConfig) sig m,
    MonadIO m
  ) =>
  m ()
eotProcess = forever $ do
  tvar <- asks etMap
  tmap <- liftIO $ readTVarIO tvar
  flip IntMap.traverseWithKey tmap $ \_ tv -> do
    liftIO (tryTakeMVar tv) >>= \case
      Nothing -> pure ()
      Just (Result tim pid res) -> cast @"et" (ProcessR pid res)
  interval <- asks einterval
  liftIO $ threadDelay interval

-------------------------------------process timeout checker
data TimeoutCheckFinish = TimeoutCheckFinish

data StartTimoutCheck where
  StartTimoutCheck :: RespVal [(Int, MVar TimeoutCheckFinish)] %1 -> StartTimoutCheck

data ProcessTimeout where
  ProcessTimeout :: Int -> ProcessTimeout

mkSigAndClass
  "SigTimeoutCheck"
  [ ''StartTimoutCheck,
    ''ProcessTimeout
  ]

data PtConfig = PtConfig
  { ptctimeout :: Int
  }

ptcProcess ::
  ( HasServer "ptc" SigTimeoutCheck '[StartTimoutCheck, ProcessTimeout] sig m,
    Has (Reader PtConfig) sig m,
    MonadIO m
  ) =>
  m ()
ptcProcess = forever $ do
  res <- call @"ptc" StartTimoutCheck
  tim <- asks ptctimeout
  liftIO $ threadDelay tim
  forM_ res $ \(pid, tmv) -> do
    liftIO (tryTakeMVar tmv) >>= \case
      Nothing -> cast @"ptc" (ProcessTimeout pid)
      Just TimeoutCheckFinish -> pure ()

-------------------------------------Manager - Work, Manager

data Stop where
  Stop :: () %1 -> Stop

data Info where
  Info :: RespVal (Int, String) %1 -> Info

data ProcessStartTimeoutCheck where
  ProcessStartTimeoutCheck :: MVar TimeoutCheckFinish -> ProcessStartTimeoutCheck

mkSigAndClass
  "SigCommand"
  [ ''Stop,
    ''Info,
    ''ProcessStartTimeoutCheck
  ]

data Create where
  Create :: Create

mkSigAndClass "SigCreate" [''Create]

mProcess ::
  ( Has
      ( MessageChan SigTimeoutCheck
          :+: MessageChan SigException
          :+: MessageChan SigCreate
      )
      sig
      m,
    HasWorkGroup "w" SigCommand '[Stop, Info, ProcessStartTimeoutCheck] sig m,
    MonadIO m
  ) =>
  m ()
mProcess = forever $ do
  withThreeMessageChan
    @SigTimeoutCheck
    @SigException
    @SigCreate
    ( \case
        SigTimeoutCheck1 (StartTimoutCheck rsp) ->
          withResp
            rsp
            ( do
                -- castAll @"w" (ProcessStartTimeoutCheck undefined)
                undefined
            )
        SigTimeoutCheck2 (ProcessTimeout pid) -> undefined
    )
    ( \case
        SigException1 (ProcessR i res) -> undefined
    )
    ( \case
        SigCreate1 Create -> undefined
    )

-------------------------------------Manager - Work, Work
