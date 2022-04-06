{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module MetricServer where

import Control.Algebra
import Control.Carrier.State.Strict
import Control.Monad.IO.Class
import Data.Kind
import GHC.TypeLits
import Process.HasServer
import Process.TH
import Process.Type
import Process.Util

data T (namespace :: Symbol) (t :: Type) = T

data L1 where
  L1 :: L1
  L2 :: L1
  L3 :: L1

class Met a where
  met :: a %1 -> Int

instance Met L1 where
  met = \case
    L1 -> 1
    L2 -> 2
    L3 -> 3

data Metric where
  Metric :: Met a => a -> Metric

mkSigAndClass
  "SigMetric"
  [ ''Metric
  ]

t :: (HasServer "metric_server" SigMetric '[Metric] sig m, MonadIO m) => m ()
t = do
  cast @"metric_server" (Metric L1)
  pure ()

tserver :: (Has (MessageChan SigMetric :+: State Int) sig m, MonadIO m) => m ()
tserver = do
  withMessageChan @SigMetric
    ( \case
        SigMetric1 (Metric l) -> put @Int (met l)
    )
