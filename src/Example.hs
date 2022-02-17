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

module Example where

import Control.Algebra
import Control.Carrier.State.Strict
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Data.Data (Proxy (Proxy))
import Process.HasServer
import Process.HasWorkGroup
import Process.Metric
import Process.TH
import Process.Type
import Process.Util

data GetVal where
  GetVal :: RespVal Int %1 -> GetVal

data PrintVal where
  PrintVal :: Int -> PrintVal

data PutVal where
  PutVal :: Int -> RespVal () %1 -> PutVal

mkSigAndClass
  "SigM"
  [ ''GetVal,
    ''PrintVal,
    ''PutVal
  ]

mkMetric "Smetric" ["s_total_get", "s_total_put", "s_total_print", "s_all"]

server :: (Has (MessageChan SigM :+: State Int :+: Metric Smetric) sig m, MonadIO m) => m ()
server = forever $ do
  inc s_all
  withMessageChan @SigM $ \case
    SigM1 (GetVal pv) ->
      withResp
        pv
        ( do
            liftIO (print "server must response")
            (liftIO $ threadDelay 1000)
            inc s_total_get
            (get @Int >>= pure)
        )
    SigM2 (PrintVal i) -> do
      inc s_total_print
      all_metrics <- getAll @Smetric Proxy
      let res = zip ["s_total_get", "s_total_put", "s_total_print", "s_all"] all_metrics
      liftIO $ print (res, i)
    SigM3 (PutVal val pv) ->
      withResp
        pv
        ( do
            liftIO (print "put val")
            inc s_total_put
            put val
        )

client :: ((HasServer "m" SigM '[GetVal, PrintVal, PutVal]) sig m, MonadIO m) => m ()
client = do
  val <- call @"m" GetVal
  cast @"m" $ PrintVal val
  forM_ [0 .. 100] $ \i -> do
    call @"m" (PutVal i)
    callTimeout @"m" 10000 GetVal >>= \case
      Nothing -> liftIO $ print "timeout"
      Just val -> cast @"m" $ PrintVal val

m :: IO ()
m = do
  chan <- newMessageChan @SigM
  tid <- forkIO $ void $ runServerWithChan chan $ runState @Int 0 $ runMetric @Smetric server
  runWithServer @"m" chan client
  threadDelay 1000000
  killThread tid
