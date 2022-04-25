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

module Example.EOT where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Reader (Reader, asks)
import Control.Carrier.State.Strict
  ( State,
  )
import Control.Concurrent
  ( threadDelay,
    tryTakeMVar,
  )
import Control.Concurrent.STM (readTVarIO)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Data (Proxy (Proxy))
import qualified Data.IntMap as IntMap
import Example.Metric
import Example.Type
import Process.HasServer (HasServer, cast)
import Process.Metric
  ( Metric,
    getAll,
    inc,
    showMetric,
  )
import Process.Type (Result (Result))

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
