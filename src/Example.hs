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
import Process.HasServer
import Process.HasWorkGroup
import Process.TH (mkSigAndClass)
import Process.Type
import Process.Util

data GetVal where
  GetVal :: PV Int %1 -> GetVal

data PrintVal where
  PrintVal :: Int -> PrintVal

data PutVal where
  PutVal :: Int -> PV () %1 -> PutVal

mkSigAndClass
  "SigM"
  [ ''GetVal,
    ''PrintVal,
    ''PutVal
  ]

server :: (Has (MessageChan SigM :+: State Int) sig m, MonadIO m) => m ()
server = forever $
  withMessageChan @SigM $ \case
    SigM1 (GetVal pv) ->
      withResp
        pv
        ( liftIO (print "server must response")
            >> (liftIO $ threadDelay 1000)
            >> (get @Int >>= pure)
        )
    SigM2 (PrintVal i) -> liftIO $ print i
    SigM3 (PutVal val pv) -> withResp pv (liftIO (print "put val") >> put val)

client :: ((HasServer "m" SigM '[GetVal, PrintVal, PutVal]) sig m, MonadIO m) => m ()
client = do
  val <- call @"m" GetVal
  cast @"m" $ PrintVal val
  forM_ [0 .. 100] $ \i -> do
    callWithTimeout @"m" 10000 (PutVal i)
    callWithTimeout @"m" 10000 GetVal >>= \case
      Nothing -> liftIO $ print "timeout"
      Just val -> cast @"m" $ PrintVal val

m :: IO ()
m = do
  chan <- newMessageChan @SigM
  tid <- forkIO $ void $ runServerWithChan chan $ runState @Int 0 server
  runWithServer @"m" chan client
  threadDelay 1000000
  killThread tid
