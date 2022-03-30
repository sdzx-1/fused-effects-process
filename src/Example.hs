{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example where

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
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.List as L
import Data.Text (pack)
-- import Text.Colour

import qualified Data.Text as T
import qualified Data.Text.Builder.Linear as TLinear
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy.Builder as TL
import Data.Time
import Process.HasServer
import Process.HasWorkGroup
import Process.Metric
import Process.TH
import Process.Type
import Process.Util
import Text.Read (readMaybe)

-------------------------------------log server

data Level = Debug | Warn | Error deriving (Eq, Ord, Show)

data Log where
  Log :: Level -> String -> Log

type CheckLevelFun = Level -> Bool

noCheck :: CheckLevelFun
noCheck _ = True

data SetLog where
  SetLog :: CheckLevelFun -> SetLog

mkSigAndClass
  "SigLog"
  [ ''Log,
    ''SetLog
  ]

mkMetric
  "Lines"
  [ "all_lines",
    "tmp_chars"
  ]

logFun :: String -> Level -> String -> String
logFun vli lv st = concat $ case lv of
  Debug -> [vli ++ "😀: " ++ st ++ "\n"]
  Warn -> [vli ++ "👿: " ++ st ++ "\n"]
  Error -> [vli ++ "☠️: " ++ st ++ "\n"]

--  Debug -> [fore green $ chunk $ pack $ vli ++ "😀: " ++ st ++ "\n"]
--  Warn -> [fore yellow $ chunk $ pack $ vli ++ "👿: " ++ st ++ "\n"]
--  Error -> [fore red $ chunk $ pack $ vli ++ "☠️: " ++ st ++ "\n"]

logServer ::
  ( Has
      ( MessageChan SigLog
          :+: Metric Lines
          :+: State CheckLevelFun
          :+: State TLinear.Builder
      )
      sig
      m,
    MonadIO m
  ) =>
  m ()
logServer = forever $ do
  withMessageChan @SigLog $ \case
    SigLog1 (Log lv st) -> do
      lvCheck <- get
      when (lvCheck lv) $ do
        inc all_lines
        li <- getVal all_lines
        let vli = show li
        chars <- getVal tmp_chars
        if chars > 1_000_000
          then do
            putVal tmp_chars 0
            bu <- get
            liftIO $ TIO.appendFile "all.log" (TLinear.runBuilder bu)
          else do
            let ln = length st
                ltxt = TL.fromString st
            putVal tmp_chars (chars + ln)
            modify @TLinear.Builder (<> TLinear.fromText (T.pack st))
        liftIO $ putStr (logFun vli lv st)
    -- liftIO $ putChunksWith With24BitColours (logFun vli lv st)
    SigLog2 (SetLog lv) -> put lv

data ProcessR where
  ProcessR :: Int -> (Either SomeException ()) -> ProcessR

mkSigAndClass "SigException" [''ProcessR]

mkMetric
  "ETmetric"
  [ "all_et_exception",
    "all_et_terminate",
    "all_et_nothing",
    "all_et_cycle"
  ]

data EotConfig = EotConfig
  { einterval :: Int,
    etMap :: TVar (IntMap (MVar Result))
  }

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
      Just (Result tim pid res) -> do
        case res of
          Left _ -> inc all_et_exception
          Right _ -> inc all_et_terminate
        cast @"et" (ProcessR pid res)
  interval <- asks einterval
  allMetrics <- getAll @ETmetric Proxy
  cast @"log" $ Log Warn (show allMetrics)
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

mkMetric
  "PTmetric"
  [ "all_pt_cycle",
    "all_pt_timeout",
    "all_pt_tcf"
  ]

newtype PtConfig = PtConfig
  { ptctimeout :: Int
  }

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
  cast @"log" $ Log Warn $ show allMetrics
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
  GetInfo :: RespVal (Maybe [(Int, String)]) %1 -> GetInfo

data StopProcess where
  StopProcess :: Int -> StopProcess

data StopAll where
  StopAll :: StopAll

data KillProcess where
  KillProcess :: Int -> KillProcess

data Fwork where
  Fwork :: [IO ()] -> Fwork

data ToSet where
  ToSet :: RespVal IntSet -> ToSet

data GetProcessInfo where
  GetProcessInfo :: RespVal [ProcessInfo] %1 -> GetProcessInfo

mkSigAndClass
  "SigCreate"
  [ ''Create,
    ''GetInfo,
    ''StopProcess,
    ''KillProcess,
    ''Fwork,
    ''StopAll,
    ''ToSet,
    ''GetProcessInfo
  ]

mkMetric
  "Wmetric"
  [ "all_fork_work",
    "all_exception",
    "all_timeout",
    "all_start_timeout_check",
    "all_create"
  ]

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
                -- cast @"log" $ Log Debug "send all check message to works"
                inc all_start_timeout_check
                sendAllCall @"w" ProcessStartTimeoutCheck
            )
        SigTimeoutCheck2 (ProcessTimeout pid) -> do
          inc all_timeout
          modify $ IntSet.insert pid
          cast @"log" $ Log Error $ "pid: " ++ show pid ++ " health check timeout!!!"
    )
    ( \case
        SigException1 (ProcessR i res) -> do
          inc all_exception
          cast @"log" $ Log Warn $ "some process terminate " ++ show (i, res)
          clearTVar @SigCommand i -- clean tvar
          cast @"log" $ Log Error $ "some tVar clear: [" ++ show i ++ "]"
          deleteChan @SigCommand i -- remove process channel
    )
    ( \case
        SigCreate1 Create -> do
          cast @"log" $ Log Warn "fork a work process"
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
                cast @"log" $ Log Error $ show allM
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
          cast @"log" $ Log Warn $ show $ snd res
        SigCreate6 StopAll -> do
          castAll @"w" Stop
        SigCreate7 (ToSet rsp) ->
          withResp rsp get
        SigCreate8 (GetProcessInfo rsp) ->
          withResp rsp (getAllInfo @SigCommand)
    )

-------------------------------------Manager - Work, Work
newtype WorkInfo = WorkInfo
  { workPid :: Int
  }

data TerminateProcess = TerminateProcess

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
      cast @"log" $ Log Warn $ "terminate process: " ++ show pid
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
              Log Warn $
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
  ( HasServer "log" SigLog '[Log, SetLog] sig m,
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
    MonadIO m
  ) =>
  m ()
client = forever $ do
  cast @"log" $ Log Debug "input "
  val <- liftIO getLine
  case val of
    "d" -> cast @"log" $ SetLog (>= Debug)
    "w" -> cast @"log" $ SetLog (>= Warn)
    "e" -> cast @"log" $ SetLog (>= Error)
    "ld" -> cast @"log" $ SetLog (== Debug)
    "lw" -> cast @"log" $ SetLog (== Warn)
    "le" -> cast @"log" $ SetLog (== Error)
    _ -> pure ()
  case readMaybe @Int val of
    Just 0 -> do
      cast @"s" StopAll
      res <- call @"s" GetProcessInfo
      cast @"log" $ Log Error $ L.intercalate "\n" (map show res)
    Just 5 -> do
      cast @"s" $ Fwork [print 1, print 2, print 3]
      res <- call @"s" GetProcessInfo
      cast @"log" $ Log Error $ L.intercalate "\n" (map show res)
    Just n -> do
      cast @"log" $ Log Debug $ "input value is: " ++ show n
      -- cast @"s" $ StopProcess n
      cast @"s" $ KillProcess n
      res <- call @"s" GetProcessInfo
      cast @"log" $ Log Error $ L.intercalate "\n" (map show res)
    Nothing -> do
      replicateM_ 200 $ cast @"s" Create
      cast @"log" $ Log Debug "cast create "
      res <- call @"s" GetInfo
      case res of
        Nothing -> cast @"log" $ Log Error "timeout: call process to all work check timeout"
        Just x0 -> cast @"log" $ Log Debug $ "all info: " ++ show x0
      toSets <- call @"s" ToSet
      cast @"log" $ Log Debug $ "all timeout set: " ++ show toSets
      res <- call @"s" GetProcessInfo
      cast @"log" $ Log Error $ L.intercalate "\n" (map show res)

----------------- run mProcess

runmProcess :: IO ()
runmProcess = do
  print "create resource"

  stimeout <- newMessageChan @SigTimeoutCheck
  se <- newMessageChan @SigException
  sc <- newMessageChan @SigCreate
  slog <- newMessageChan @SigLog
  tvar <- newTVarIO IntMap.empty

  print "fork log server"
  forkIO $
    void $
      runMetric @Lines $
        runState noCheck $
          runState @TLinear.Builder mempty $
            runServerWithChan slog logServer

  print "fork et process"
  forkIO $
    void $
      runWithServer @"et" se $
        runWithServer @"log" slog $
          runMetric @ETmetric $
            runReader (EotConfig 100_0000 tvar) $
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
              (PtConfig 100_0000)
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
        runWithServer @"s" sc client

  forever $ do
    threadDelay 1000_0000
