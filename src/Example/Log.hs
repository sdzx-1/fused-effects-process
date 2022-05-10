{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.Log where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.State.Strict
  ( State,
  )
import Control.Effect.Optics (use, (%=), (.=))
import Control.Monad (forever, when)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Text as T
import qualified Data.Text.Builder.Linear as TLinear
import qualified Data.Text.IO as TIO
import Example.Metric
import Example.Type
  ( Log (Log),
    LogState,
    LogType (LogFile, LogPrint),
    SetLog (SetLog),
    SigLog (..),
    Stop (Stop),
    Switch (Switch),
    batchSize,
    checkLevelFun,
    linearBuilder,
    logFilePath,
    logFun,
    printOut,
    useLogFile,
  )
import Process.Metric
  ( Metric,
    getAll,
    getVal,
    inc,
    putVal,
    showMetric,
  )
import Process.Util
  ( MessageChan,
    whenM,
    withMessageChan,
    withResp,
  )

-------------------------------------log server
logServer ::
  ( MonadIO m,
    Has (MessageChan SigLog) sig m,
    Has (Metric Lines :+: State LogState) sig m
  ) =>
  m ()
logServer = forever $
  withMessageChan @SigLog $ \case
    SigLog1 (Log lv st) -> do
      lvCheck <- use checkLevelFun
      when (lvCheck lv) $ do
        inc all_lines
        li <- show <$> getVal all_lines
        whenM (use printOut) $ do
          logCount <- getAll @Lines
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
        $ case t of
          LogFile -> do
            liftIO $ putStrLn "switch logFile"
            useLogFile %= not
          LogPrint -> do
            liftIO $ putStrLn "switch printOut"
            printOut %= not
    SigLog4 Stop -> do
      whenM (use useLogFile) $ do
        bu <- use linearBuilder
        file_path <- use logFilePath
        liftIO $
          TIO.appendFile
            file_path
            (TLinear.runBuilder bu)
