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

module Example.Metric where

import Process.Metric
  ( Default (..),
    K (..),
    NameVector (..),
    Vlength (..),
  )
import Process.TH (fromList, mkMetric)

mkMetric
  "Wmetric"
  [ "all_fork_work",
    "all_exception",
    "all_timeout",
    "all_start_timeout_check",
    "all_create"
  ]

mkMetric
  "Lines"
  [ "all_lines",
    "tmp_chars"
  ]

mkMetric
  "PTmetric"
  [ "all_pt_cycle",
    "all_pt_timeout",
    "all_pt_tcf"
  ]

mkMetric
  "ETmetric"
  [ "all_et_exception",
    "all_et_terminate",
    "all_et_nothing",
    "all_et_cycle"
  ]
