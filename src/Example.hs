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

mkSigAndClass
  "SigM"
  [ ''GetVal,
    ''PrintVal
  ]

server :: (Has (MessageChan SigM) sig m, MonadIO m) => m ()
server = forever $
  withMessageChan @SigM $ \case
    SigM1 (GetVal pv) -> withResp pv (liftIO (print "server must response") >> pure 10)
    SigM2 (PrintVal i) -> liftIO $ print i

client :: ((HasServer "m" SigM '[GetVal, PrintVal]) sig m, MonadIO m) => m ()
client = do
  val <- call @"m" GetVal
  cast @"m" $ PrintVal val

m :: IO ()
m = do
  chan <- newMessageChan @SigM
  tid <- forkIO $ void $ runServerWithChan chan server
  runWithServer @"m" chan client
  threadDelay 1000000
  killThread tid
