{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Raft where

import Control.Algebra
import Control.Carrier.Error.Either
import Control.Carrier.State.Strict
import Control.Concurrent.STM (atomically)
import Control.Effect.Error
import Control.Effect.Optics
import Control.Monad
import Control.Monad.IO.Class
import Optics (makeLenses)
import Process.HasPeerGroup
import Process.HasServer
import Process.Metric
import Process.TChan
import Process.TH
import Process.Timer
import Process.Type (ToList, ToSig (..))
import Process.Util

data Hello where
  A :: RespVal String %1 -> Hello

mkSigAndClass
  "SigRPC"
  [''Hello]

data Role = Follower | Candidate | Leader deriving (Show, Eq, Ord)

data ProcessError = ProcessError

data CoreState = CoreState
  { _nodeRole :: Role,
    _nodeTitle :: String,
    _timeout :: Timeout
  }
  deriving (Show)

makeLenses ''CoreState

t1 ::
  ( MonadIO m,
    HasPeerServer "peer" SigRPC '[Hello] sig m,
    Has (State CoreState :+: Error ProcessError) sig m
  ) =>
  m ()
t1 = forever $ do
  use nodeRole >>= \case
    Follower -> do
      tc <- getChan @"peer"
      readMessageChan tc \case
        SigRPC1 (A rsp) ->
          undefined
            rsp
            undefined
    Candidate -> undefined
    Leader -> undefined
  res <- callAll @"peer" A
  undefined

r1 :: IO ()
r1 = do
  tr <- newTimeout 5
  void $
    runWithPeers @"peer" (NodeID 1) $
      runError @ProcessError $
        runState (CoreState Follower "" tr) $ t1
