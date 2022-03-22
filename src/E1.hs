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
import Control.Carrier.State.Strict
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad
import Control.Monad.IO.Class
import Data.Data (Proxy (Proxy))
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Time
import Process.HasServer
import Process.HasWorkGroup
import Process.Metric
import Process.TH
import Process.Type
import Process.Util
import Text.Read (readMaybe)

-------------------------------------exception or terminate

data ProcessR where
  ProcessR :: Int -> (Either SomeException ()) -> ProcessR

mkSigAndClass "SigException" [''ProcessR]

mkMetric
  "ETmetric"
  [ "all_exception",
    "all_terminate",
    "all_nothing",
    "all_cycle"
  ]

data EotConfig = EotConfig
  { einterval :: Int,
    etMap :: TVar (IntMap (MVar Result))
  }

eotProcess ::
  ( HasServer "et" SigException '[ProcessR] sig m,
    Has
      ( Reader EotConfig
          :+: State Int
          :+: Metric ETmetric
      )
      sig
      m,
    MonadIO m
  ) =>
  m ()
eotProcess = forever $ do
  inc all_cycle
  tvar <- asks etMap
  tmap <- liftIO $ readTVarIO tvar
  flip IntMap.traverseWithKey tmap $ \_ tv -> do
    liftIO (tryTakeMVar tv) >>= \case
      Nothing -> do
        inc all_nothing
        pure ()
      Just (Result tim pid res) -> do
        case res of
          Left _ -> inc all_exception
          Right _ -> inc all_terminate
        cast @"et" (ProcessR pid res)
  interval <- asks einterval
  allMetrics <- getAll @ETmetric Proxy
  liftIO $ print allMetrics
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

newtype PtConfig = PtConfig
  { ptctimeout :: Int
  }

ptcProcess ::
  ( HasServer
      "ptc"
      SigTimeoutCheck
      '[StartTimoutCheck, ProcessTimeout]
      sig
      m,
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

data ProcessWork where
  ProcessWork :: IO () -> RespVal () %1 -> ProcessWork

mkSigAndClass
  "SigCommand"
  [ ''Stop,
    ''Info,
    ''ProcessStartTimeoutCheck,
    ''ProcessWork
  ]

data Create where
  Create :: Create

data GetInfo where
  GetInfo :: RespVal [(Int, String)] %1 -> GetInfo

data StopProcess where
  StopProcess :: Int -> StopProcess

data StopAll where
  StopAll :: StopAll

data KillProcess where
  KillProcess :: Int -> KillProcess

data Fwork where
  Fwork :: [IO ()] -> Fwork

mkSigAndClass
  "SigCreate"
  [ ''Create,
    ''GetInfo,
    ''StopProcess,
    ''KillProcess,
    ''Fwork,
    ''StopAll
  ]

mProcess ::
  ( Has
      ( MessageChan SigTimeoutCheck
          :+: MessageChan SigException
          :+: MessageChan SigCreate
      )
      sig
      m,
    HasWorkGroup
      "w"
      SigCommand
      '[ Stop,
         Info,
         ProcessStartTimeoutCheck,
         ProcessWork
       ]
      sig
      m,
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
        SigCreate5 (Fwork ios) -> do
          res <- sendWorks @"w" ios ProcessWork
          liftIO $ print $ snd res
        SigCreate6 StopAll -> do
          castAll @"w" Stop
    )

-------------------------------------Manager - Work, Work

newtype WorkInfo = WorkInfo
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
    SigCommand4 (ProcessWork work rsp) -> do
      withResp
        rsp
        ( do
            liftIO work
            pure ()
        )

------------------------ create client
client ::
  ( HasServer
      "s"
      SigCreate
      '[ Create,
         GetInfo,
         StopProcess,
         KillProcess,
         Fwork,
         StopAll
       ]
      sig
      m,
    MonadIO m
  ) =>
  m ()
client = forever $ do
  liftIO $ print "input "
  val <- liftIO getLine
  case readMaybe @Int val of
    Just 0 -> do
      cast @"s" StopAll
    Just 5 -> do
      cast @"s" $ Fwork [print 1, print 2, print 3]
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
        runMetric @ETmetric $
          runReader (EotConfig 1000000 tvar) $
            runState @Int
              1
              eotProcess

  print "fork ptc process"
  forkIO $
    void $
      runWithServer @"ptc" stimeout $
        runReader
          (PtConfig 1000000)
          ptcProcess

  print "fork server process"
  forkIO $
    void $
      runServerWithChan stimeout $
        runServerWithChan se $
          runServerWithChan sc $
            runWithWorkGroup' @"w"
              tvar
              mProcess

  print "fork client"
  forkIO $ void $ runWithServer @"s" sc client

  forever $ do
    threadDelay 10000000
