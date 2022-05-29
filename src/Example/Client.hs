{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Example.Client where

import Control.Algebra (Has)
import Control.Carrier.Reader (Reader, ask)
import Control.Concurrent
  ( MVar,
    putMVar,
    threadDelay,
  )
import Control.Monad (forever, replicateM_)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.List as L
import Example.Type
import Control.Carrier.HasServer (HasServer, call, cast)
import Process.Type (NodeId (..))
import Text.Read (readMaybe)

------------------------ create client
client ::
  ( MonadIO m,
    Has (Reader (MVar ())) sig m,
    HasServer "log" SigLog '[Log, SetLog, Switch] sig m,
    HasServer "s" SigCreate '[Create, GetInfo, StopProcess, KillProcess, Fwork, StopAll, ToSet, GetProcessInfo] sig m
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
        Just 0 -> cast @"s" StopAll
        Just 5 -> cast @"s" $ Fwork [print 1, print 2, print 3]
        Just n -> do
          cast @"log" $ LD $ "input value is: " ++ show n
          -- cast @"s" $ StopProcess n
          cast @"s" $ KillProcess $ NodeId n
        Nothing -> do
          replicateM_ 200 $ cast @"s" Create
          cast @"log" $ LD "cast create "
          res <- call @"s" GetInfo
          case res of
            Nothing -> cast @"log" $ LE "timeout: call process to all work check timeout"
            Just x0 -> cast @"log" $ LD $ "all info: " ++ show x0

ls ::
  ( HasServer "s" SigCreate '[LogStatus] sig m,
    MonadIO m
  ) =>
  m ()
ls = forever $ do
  cast @"s" LogStatus
  liftIO $ threadDelay 1_000_000
