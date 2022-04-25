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

module Example.PTC where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Reader (Reader, asks)
import Control.Concurrent
  ( threadDelay,
    tryTakeMVar,
  )
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Data (Proxy (Proxy))
import Example.Metric
import Example.Type
import Process.HasServer (HasServer, call, cast)
import Process.Metric
  ( Metric,
    getAll,
    inc,
    showMetric,
  )

-------------------------------------process timeout checker
ptcProcess ::
  ( MonadIO m,
    HasServer "log" SigLog '[Log] sig m,
    Has (Reader PtConfig :+: Metric PTmetric) sig m,
    HasServer "ptc" SigTimeoutCheck '[StartTimoutCheck, ProcessTimeout] sig m
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
