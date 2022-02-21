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
import Control.Carrier.Error.Either
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
import Text.Read (readMaybe)

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
  Stop :: Stop

data Info where
  Info :: RespVal (Int, String) %1 -> Info

data ProcessStartTimeoutCheck where
  ProcessStartTimeoutCheck :: RespVal TimeoutCheckFinish %1 -> ProcessStartTimeoutCheck

mkSigAndClass
  "SigCommand"
  [ ''Stop,
    ''Info,
    ''ProcessStartTimeoutCheck
  ]

data Create where
  Create :: Create

data GetInfo where
  GetInfo :: RespVal [(Int, String)] %1 -> GetInfo

data StopProcess where
  StopProcess :: Int -> StopProcess

data KillProcess where
  KillProcess :: Int -> KillProcess

mkSigAndClass
  "SigCreate"
  [''Create, ''GetInfo, ''StopProcess, ''KillProcess]

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
                liftIO $ print "send all check message to works"
                sendAllCall @"w" ProcessStartTimeoutCheck
            )
        SigTimeoutCheck2 (ProcessTimeout pid) -> do
          liftIO $ print $ "pid: " ++ show pid ++ " health check timeout!!!"
    )
    ( \case
        SigException1 (ProcessR i res) -> do
          liftIO $ print $ "some process terminate " ++ show (i, res)
          clearTVar @SigCommand i -- clean tvar
          deleteChan @SigCommand i -- remove process channel
    )
    ( \case
        SigCreate1 Create -> do
          liftIO $ print "fork a work process"
          createWorker @SigCommand $ \idx ch ->
            void $
              runWorkerWithChan ch $
                runReader (WorkInfo idx) $
                  runError @TerminateProcess $
                    mWork
        SigCreate2 (GetInfo rsp) -> withResp rsp (callAll @"w" Info)
        SigCreate3 (StopProcess i) -> do
          castById @"w" i Stop
          deleteChan @SigCommand i
        SigCreate4 (KillProcess i) -> do
          killWorker @SigCommand i
          deleteChan @SigCommand i
    )

-------------------------------------Manager - Work, Work

data WorkInfo = WorkInfo
  { workPid :: Int
  }

data TerminateProcess = TerminateProcess

mWork ::
  ( Has
      ( MessageChan SigCommand
          :+: Reader WorkInfo
          :+: Error TerminateProcess
      )
      sig
      m,
    MonadIO m
  ) =>
  m ()
mWork = forever $ do
  withMessageChan @SigCommand $ \case
    SigCommand1 Stop -> do
      pid <- asks workPid
      liftIO $ print $ "terminate process: " ++ show pid
      throwError TerminateProcess
    SigCommand2 (Info rsp) ->
      withResp
        rsp
        ( do
            pid <- asks workPid
            pure (pid, "work is running")
        )
    SigCommand3 (ProcessStartTimeoutCheck rsp) ->
      withResp
        rsp
        ( do
            pid <- asks workPid
            liftIO $ print $ "process " ++ show pid ++ " response timoue check"
            pure TimeoutCheckFinish
        )

------------------------ create client
client ::
  ( HasServer "s" SigCreate '[Create, GetInfo, StopProcess, KillProcess] sig m,
    MonadIO m
  ) =>
  m ()
client = forever $ do
  liftIO $ print "input "
  val <- liftIO getLine
  case readMaybe @Int val of
    Just n -> do
      liftIO $ print $ "input value is: " ++ show n
      cast @"s" $ StopProcess n
      -- cast @"s" $ KillProcess n
    Nothing -> do
      cast @"s" Create
      liftIO $ print "cast create "
      res <- call @"s" GetInfo
      liftIO $ print $ "all info: " ++ show res

----------------- run mProcess

runmProcess :: IO ()
runmProcess = do
  print "create resource"

  stimeout <- newMessageChan @SigTimeoutCheck
  se <- newMessageChan @SigException
  sc <- newMessageChan @SigCreate
  tvar <- newTVarIO IntMap.empty

  print "fork et process"
  forkIO $
    void $
      runWithServer @"et" se $
        runReader (EotConfig 1000000 tvar) $
          eotProcess

  print "fork ptc process"
  forkIO $
    void $
      runWithServer @"ptc" stimeout $
        runReader (PtConfig 1000000) $
          ptcProcess

  print "fork server process"
  forkIO $
    void $
      runServerWithChan stimeout $
        runServerWithChan se $
          runServerWithChan sc $
            runWithWorkGroup' @"w" tvar $
              mProcess

  print "start client"
  runWithServer @"s" sc client
