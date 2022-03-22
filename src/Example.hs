{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example where

import Control.Algebra
import Control.Carrier.Reader
import Control.Carrier.State.Strict
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Data.Data (Proxy (Proxy))
-- import Data.Vector (fromList)
import Process.HasServer
import Process.HasWorkGroup
import Process.Metric
import Process.TH (fromList, mkMetric, mkSigAndClass)
import Process.Type
import Process.Util

------ client - server
data GetVal where
  GetVal :: RespVal Int %1 -> GetVal

data PrintVal where
  PrintVal :: Int -> PrintVal

data PutVal where
  PutVal :: Int -> PutVal

mkSigAndClass
  "SigM"
  [ ''GetVal,
    ''PrintVal,
    ''PutVal
  ]

--------------- work -- manager

data A where
  A :: RespVal Int %1 -> A

data B where
  B :: Int -> B

mkSigAndClass
  "SigW"
  [ ''A,
    ''B
  ]

-------------------

mkMetric
  "Smetric"
  [ "s_total_get",
    "s_total_put",
    "s_all"
  ]

server ::
  ( Has
      ( MessageChan SigW
          :+: MessageChan SigM
          :+: State Int
          :+: Metric Smetric
      )
      sig
      m,
    MonadIO m
  ) =>
  m ()
server = forever $ do
  inc s_all
  withTwoMessageChan @SigW @SigM
    ( \case
        SigW1 (A rsp) -> withResp rsp (pure 1)
        SigW2 (B i) -> liftIO $ putStrLn $ "cast val is " ++ show i
    )
    ( \case
        SigM1 (GetVal pv) ->
          withResp
            pv
            ( do
                liftIO (print "server must response")
                liftIO $ threadDelay 1000
                inc s_total_get
                get @Int >>= pure
            )
        SigM2 (PrintVal i) -> do
          all_metrics <- getAll @Smetric Proxy
          liftIO $ print (all_metrics, i)
        SigM3 (PutVal val) ->
          do
            liftIO (print "put val")
            inc s_total_put
            put val
    )

client ::
  ( (HasWorkGroup "w" SigW '[A, B] sig m),
    (HasServer "m" SigM '[GetVal, PrintVal, PutVal]) sig m,
    Has (Reader (TChan (Some SigM))) sig m,
    MonadIO m
  ) =>
  m ()
client = do
  chan <- ask @(TChan (Some SigM))
  createWorker @SigW $ \_ c ->
    void $
      runWorkerWithChan c $
        runServerWithChan chan $
          runState @Int 0 $
            runMetric @Smetric server

  la <- callAll @"w" A
  liftIO $ print la
  castAll @"w" $ B 10

  val <- call @"m" GetVal
  cast @"m" $ PrintVal val
  forM_ [0 .. 5] $ \i -> do
    cast @"m" (PutVal i)
    timeoutCall @"m" 10000 GetVal >>= \case
      Nothing -> liftIO $ print "timeout"
      Just val -> cast @"m" $ PrintVal val

m :: IO ()
m = do
  chanM <- newMessageChan @SigM
  chanW <- newMessageChan @SigW

  runWithServer @"m" @SigM chanM $
    runWithWorkGroup @"w" @SigW $
      runReader chanM client

  threadDelay 1000000
