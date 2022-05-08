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

module Example.Type where

import Control.Concurrent (MVar)
import Control.Concurrent.STM (TMVar, TVar)
import Control.Exception (SomeException)
import Data.IntMap (IntMap)
import Data.IntSet (IntSet)
import qualified Data.Text.Builder.Linear as TLinear
import Optics (makeLenses)
import Process.TH (mkSigAndClass)
import Process.Type
  ( ProcessInfo,
    RespVal,
    Result,
    ToList,
    ToSig (..),
  )

data Stop where
  Stop :: Stop

-------------------------------------log server
data Level = Debug | Warn | Error deriving (Eq, Ord, Show)

data Log where
  Log :: Level -> String -> Log

pattern LD :: String -> Log
pattern LD s = Log Debug s

pattern LW :: String -> Log
pattern LW s = Log Warn s

pattern LE :: String -> Log
pattern LE s = Log Error s

type CheckLevelFun = Level -> Bool

logFun :: String -> Level -> String -> String
logFun vli lv st = concat $ case lv of
  Debug -> [vli ++ "😀: \n" ++ st ++ "\n"]
  Warn -> [vli ++ "👿: \n" ++ st ++ "\n"]
  Error -> [vli ++ "☠️: \n" ++ st ++ "\n"]

data SetLog where
  SetLog :: CheckLevelFun -> SetLog

data LogType = LogFile | LogPrint

-- | enable log type
--  file or console
data Switch where
  Switch :: LogType -> RespVal () %1 -> Switch

data LogState = LogState
  { _checkLevelFun :: CheckLevelFun,
    _linearBuilder :: TLinear.Builder,
    _useLogFile :: Bool,
    _batchSize :: Int,
    _logFilePath :: FilePath,
    _printOut :: Bool
  }

makeLenses ''LogState

noCheck :: CheckLevelFun
noCheck _ = True

logState :: LogState
logState =
  LogState
    { _checkLevelFun = noCheck,
      _linearBuilder = mempty,
      _useLogFile = False,
      _batchSize = 30_000,
      _logFilePath = "all.log",
      _printOut = True
    }

mkSigAndClass
  "SigLog"
  [ ''Log,
    ''SetLog,
    ''Switch,
    ''Stop
  ]

-------------------------------------eot server
data ProcessR where
  ProcessR :: Int -> (Either SomeException ()) -> ProcessR

mkSigAndClass "SigException" [''ProcessR]

data EotConfig = EotConfig
  { einterval :: Int,
    etMap :: TVar (IntMap (MVar Result))
  }

-------------------------------------process timeout checker
data TimeoutCheckFinish = TimeoutCheckFinish

data StartTimoutCheck where
  StartTimoutCheck :: RespVal [(Int, TMVar TimeoutCheckFinish)] %1 -> StartTimoutCheck

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

-------------------------------------Manager - Work, Manager
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

data LogStatus where
  LogStatus :: LogStatus

mkSigAndClass
  "SigCreate"
  [ ''Create,
    ''GetInfo,
    ''StopProcess,
    ''KillProcess,
    ''Fwork,
    ''StopAll,
    ''ToSet,
    ''GetProcessInfo,
    ''LogStatus
  ]

-------------------------------------Manager - Work, Work
newtype WorkInfo = WorkInfo
  { workPid :: Int
  }

data TerminateProcess = TerminateProcess
