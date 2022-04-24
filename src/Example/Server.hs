{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.Server where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Error.Either (Error, runError, throwError)
import Control.Carrier.Reader (Reader, ask, asks, runReader)
import Control.Carrier.State.Strict
  ( State,
    get,
    modify,
    runState,
  )
import Control.Concurrent
  ( MVar,
    forkIO,
    newEmptyMVar,
    putMVar,
    takeMVar,
    threadDelay,
    tryTakeMVar,
  )
import Control.Concurrent.STM (newTVarIO, readTVarIO)
import Control.Effect.Optics (use, (%=), (.=))
import Control.Monad (forM_, forever, replicateM_, void, when)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Data (Proxy (Proxy))
import qualified Data.IntMap as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.List as L
import qualified Data.Text as T
import qualified Data.Text.Builder.Linear as TLinear
import qualified Data.Text.IO as TIO
import Example.Metric
import Example.Type
import Process.HasServer (HasServer, call, cast, runWithServer)
import Process.HasWorkGroup
  ( HasWorkGroup,
    castAll,
    castById,
    clearTVar,
    createWorker,
    deleteChan,
    getAllInfo,
    killWorker,
    runWithWorkGroup',
    sendAllCall,
    sendWorks,
    timeoutCallAll,
  )
import Process.Metric
  ( Metric,
    getAll,
    getVal,
    inc,
    putVal,
    runMetric,
    showMetric,
  )
import Process.Type (Result (Result))
import Process.Util
  ( MessageChan,
    newMessageChan,
    runServerWithChan,
    runWorkerWithChan,
    whenM,
    withMessageChan,
    withResp,
    withThreeMessageChan,
  )
import Text.Read (readMaybe)

-------------------------------------log server
logServer ::
  ( Has
      ( MessageChan SigLog
          :+: Metric Lines
          :+: State LogState
      )
      sig
      m,
    MonadIO m
  ) =>
  m ()
logServer = forever $ do
  withMessageChan @SigLog $ \case
    SigLog1 (Log lv st) -> do
      lvCheck <- use checkLevelFun
      when (lvCheck lv) $ do
        inc all_lines
        li <- show <$> getVal all_lines
        whenM (use printOut) $ do
          logCount <- getAll @Lines Proxy
          liftIO $ do
            putStrLn $ showMetric logCount
            putStrLn (logFun li lv st)
        whenM (use useLogFile) $ do
          chars <- getVal tmp_chars
          batch <- use batchSize
          if chars > batch
            then do
              putVal tmp_chars 0
              bu <- use linearBuilder
              file_path <- use logFilePath
              liftIO $
                TIO.appendFile
                  file_path
                  (TLinear.runBuilder bu)
            else do
              let ln = length st
              putVal tmp_chars (chars + ln)
              linearBuilder %= (<> TLinear.fromText (T.pack st))
    SigLog2 (SetLog lv) -> checkLevelFun .= lv
    SigLog3 (Switch t rsp) ->
      withResp
        rsp
        ( case t of
            LogFile -> do
              liftIO $ putStrLn "switch logFile"
              useLogFile %= not
            LogPrint -> do
              liftIO $ putStrLn "switch printOut"
              printOut %= not
        )
    SigLog4 Stop -> do
      whenM (use useLogFile) $ do
        bu <- use linearBuilder
        file_path <- use logFilePath
        liftIO $
          TIO.appendFile
            file_path
            (TLinear.runBuilder bu)

-------------------------------------eot server
eotProcess ::
  ( HasServer "et" SigException '[ProcessR] sig m,
    HasServer "log" SigLog '[Log] sig m,
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
  inc all_et_cycle
  tvar <- asks etMap
  tmap <- liftIO $ readTVarIO tvar
  flip IntMap.traverseWithKey tmap $ \_ tv -> do
    liftIO (tryTakeMVar tv) >>= \case
      Nothing -> do
        inc all_et_nothing
        pure ()
      Just (Result _ pid res) -> do
        case res of
          Left _ -> inc all_et_exception
          Right _ -> inc all_et_terminate
        cast @"et" (ProcessR pid res)
  interval <- asks einterval
  allMetrics <- getAll @ETmetric Proxy
  cast @"log" $ LW (showMetric allMetrics)
  liftIO $ threadDelay interval

-------------------------------------process timeout checker
ptcProcess ::
  ( HasServer "log" SigLog '[Log] sig m,
    HasServer
      "ptc"
      SigTimeoutCheck
      '[StartTimoutCheck, ProcessTimeout]
      sig
      m,
    Has (Reader PtConfig :+: Metric PTmetric) sig m,
    MonadIO m
  ) =>
  m ()
ptcProcess = forever $ do
  allMetrics <- getAll @PTmetric Proxy
  cast @"log" $ LW $ showMetric allMetrics
  inc all_pt_cycle
  res <- call @"ptc" StartTimoutCheck
  tim <- asks ptctimeout
  liftIO $ threadDelay tim
  forM_ res $ \(pid, tmv) -> do
    liftIO (tryTakeMVar tmv) >>= \case
      Nothing -> do
        inc all_pt_timeout
        cast @"ptc" (ProcessTimeout pid)
      Just TimeoutCheckFinish -> do
        inc all_pt_tcf
        pure ()

-------------------------------------Manager - Work, Manager

mProcess ::
  ( HasServer "log" SigLog '[Log] sig m,
    Has
      ( MessageChan SigTimeoutCheck
          :+: MessageChan SigException
          :+: MessageChan SigCreate
          :+: MessageChan SigLog
          :+: State IntSet
          :+: Metric Wmetric
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
                cast @"log" $ LD "send all check message to works"
                inc all_start_timeout_check
                sendAllCall @"w" ProcessStartTimeoutCheck
            )
        SigTimeoutCheck2 (ProcessTimeout pid) -> do
          inc all_timeout
          modify $ IntSet.insert pid
          cast @"log" $ LE $ "pid: " ++ show pid ++ " health check timeout!!!"
    )
    ( \case
        SigException1 (ProcessR i res) -> do
          inc all_exception
          cast @"log" $ LW $ "some process terminate " ++ show (i, res)
          clearTVar @SigCommand i -- clean tvar
          cast @"log" $ LE $ "some tVar clear: [" ++ show i ++ "]"
          deleteChan @SigCommand i -- remove process channel
    )
    ( \case
        SigCreate1 Create -> do
          cast @"log" $ LW "fork a work process"
          slog <- ask
          inc all_create
          createWorker @SigCommand $ \idx ch ->
            void $
              runWorkerWithChan ch $
                runReader (WorkInfo idx) $
                  runError @TerminateProcess $
                    runWithServer @"log"
                      slog
                      mWork
        SigCreate2 (GetInfo rsp) ->
          withResp
            rsp
            ( do
                allM <- getAll @Wmetric Proxy
                cast @"log" $ LE $ showMetric allM
                timeoutCallAll @"w" 1_000_000 Info
            )
        SigCreate3 (StopProcess i) -> do
          castById @"w" i Stop
          deleteChan @SigCommand i
        SigCreate4 (KillProcess i) -> do
          killWorker @SigCommand i
          deleteChan @SigCommand i
        SigCreate5 (Fwork ios) -> do
          res <- sendWorks @"w" ios ProcessWork
          inc all_fork_work
          cast @"log" $ LW $ show $ snd res
        SigCreate6 StopAll -> do
          castAll @"w" Stop
        SigCreate7 (ToSet rsp) ->
          withResp rsp get
        SigCreate8 (GetProcessInfo rsp) ->
          withResp rsp (getAllInfo @SigCommand)
    )

-------------------------------------Manager - Work, Work
mWork ::
  ( HasServer "log" SigLog '[Log] sig m,
    Has
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
      cast @"log" $ LW $ "terminate process: " ++ show pid
      throwError TerminateProcess
    SigCommand2 (Info rsp) ->
      withResp
        rsp
        ( do
            pid <- asks workPid
            pure (pid, "running")
        )
    SigCommand3 (ProcessStartTimeoutCheck rsp) ->
      withResp
        rsp
        ( do
            pid <- asks workPid
            cast @"log" $
              LW $
                "process "
                  ++ show pid
                  ++ " response timoue check"
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
  ( HasServer "log" SigLog '[Log, SetLog, Switch] sig m,
    HasServer
      "s"
      SigCreate
      '[ Create,
         GetInfo,
         StopProcess,
         KillProcess,
         Fwork,
         StopAll,
         ToSet,
         GetProcessInfo
       ]
      sig
      m,
    Has (Reader (MVar ())) sig m,
    MonadIO m
  ) =>
  m ()
client = forever $ do
  res <- call @"s" GetProcessInfo
  cast @"log" $ LE $ L.intercalate "\n" (map show res)
  val <- liftIO getLine
  case val of
    "q" -> do
      cast @"log" $ LE "terminate threads"
      liftIO $ threadDelay 100_000
      ftm <- ask
      liftIO $ putMVar ftm ()
    "f" -> call @"log" $ Switch LogFile
    "p" -> call @"log" $ Switch LogPrint
    "d" -> cast @"log" $ SetLog (>= Debug)
    "w" -> cast @"log" $ SetLog (>= Warn)
    "e" -> cast @"log" $ SetLog (>= Error)
    "ld" -> cast @"log" $ SetLog (== Debug)
    "lw" -> cast @"log" $ SetLog (== Warn)
    "le" -> cast @"log" $ SetLog (== Error)
    _ -> do
      case readMaybe @Int val of
        Just 0 -> do
          cast @"s" StopAll
        Just 5 -> do
          cast @"s" $ Fwork [print 1, print 2, print 3]
        Just n -> do
          cast @"log" $ LD $ "input value is: " ++ show n
          -- cast @"s" $ StopProcess n
          cast @"s" $ KillProcess n
        Nothing -> do
          replicateM_ 200 $ cast @"s" Create
          cast @"log" $ LD "cast create "
          res <- call @"s" GetInfo
          case res of
            Nothing -> cast @"log" $ LE "timeout: call process to all work check timeout"
            Just x0 -> cast @"log" $ LD $ "all info: " ++ show x0

----------------- run mProcess

runmProcess :: IO ()
runmProcess = do
  print "create resource"

  stimeout <- newMessageChan @SigTimeoutCheck
  se <- newMessageChan @SigException
  sc <- newMessageChan @SigCreate
  slog <- newMessageChan @SigLog
  tvar <- newTVarIO IntMap.empty
  ftmvar <- newEmptyMVar @()

  print "fork log server"
  forkIO $
    void $
      runMetric @Lines $
        runState logState $
          runServerWithChan slog logServer

  print "fork et process"
  forkIO $
    void $
      runWithServer @"et" se $
        runWithServer @"log" slog $
          runMetric @ETmetric $
            runReader (EotConfig 1_000_000 tvar) $
              runState @Int
                1
                eotProcess

  print "fork ptc process"
  forkIO $
    void $
      runWithServer @"ptc" stimeout $
        runMetric @PTmetric $
          runWithServer @"log" slog $
            runReader
              (PtConfig 1_000_000)
              ptcProcess

  print "fork server process"
  forkIO $
    void $
      runServerWithChan stimeout $
        runServerWithChan se $
          runServerWithChan sc $
            runWithServer @"log" slog $
              runReader slog $
                runMetric @Wmetric $
                  runState @IntSet IntSet.empty $
                    runWithWorkGroup' @"w"
                      tvar
                      mProcess

  print "fork client"
  forkIO $
    void $
      runWithServer @"log" slog $
        runReader ftmvar $
          runWithServer @"s" sc client

  takeMVar ftmvar
