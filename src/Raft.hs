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
import Control.Applicative
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
import Process.Type (Some (..), ToList, ToSig (..))
import Process.Util hiding (withResp)

data Vote where
  Vote :: RespVal Bool %1 -> Vote

data TC where
  A :: RespVal String %1 -> TC

mkSigAndClass
  "SigRPC"
  [ ''TC,
    ''Vote
  ]

data Role = Follower | Candidate | Leader deriving (Show, Eq, Ord)

data ProcessError
  = TimeoutError
  | HalfVoteFailed
  | HalfVoteSuccess
  | NetworkError
  deriving (Show, Eq, Ord)

data CoreState = CoreState
  { _nodeRole :: Role,
    _timeout :: Timeout
  }
  deriving (Show)

makeLenses ''CoreState

readMessageChanWithTimeout ::
  forall f es sig m.
  (MonadIO m, Has (Error ProcessError) sig m) =>
  Timeout ->
  TChan (Some f) ->
  (forall s. f s %1 -> m ()) ->
  m ()
readMessageChanWithTimeout to tc f = do
  v <- liftIO $ atomically $ waitTimeout to <|> (Just <$> readTChan tc)
  case v of
    Nothing -> throwError TimeoutError
    Just (Some v) -> f v

mkMetric
  "Counter"
  [ "all_cycle",
    "all_leader_timeout",
    "all_vote",
    "all_network_error"
  ]

t1 ::
  ( MonadIO m,
    Has (Metric Counter) sig m,
    HasPeerGroup "peer" SigRPC '[TC, Vote] sig m,
    Has (State CoreState :+: Error ProcessError) sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_cycle
  use nodeRole >>= \case
    Follower -> do
      (tc, timer) <- (,) <$> getChan @"peer" <*> use timeout
      catchError @ProcessError
        ( readMessageChanWithTimeout timer tc \case
            SigRPC1 (A rsp) ->
              withResp
                rsp
                ( pure "hello"
                )
        )
        ( \case
            TimeoutError -> do
              inc all_leader_timeout
              -- timeout, need new leader select
              -- change role to Candidate
              nodeRole .= Candidate
              undefined
        )
    Candidate -> do
      cs <- callAll @"peer" Vote
      timer <- liftIO $ newTimeout 2
      size <- peerSize @"peer"
      -- clean all_vote
      putVal all_vote 0
      catchError @ProcessError
        ( forM_ [1 .. length cs + 1] $ \index -> do
            when (index == length cs + 1) (throwError HalfVoteFailed)
            votes <- getVal all_vote
            when (votes >= (size `div` 2)) (throwError HalfVoteSuccess)
            res <- liftIO $ atomically $ waitTimeout timer <|> (Just <$> waitTMVars cs)
            case res of
              Nothing -> do
                -- cluster timeout ?? maybe network error
                inc all_network_error
                throwError NetworkError
              Just (nid, bool) -> do
                -- vote true, inc all_votes
                when bool (inc all_vote)
        )
        ( \case
            -- vote sucess, set role to leader
            HalfVoteSuccess -> nodeRole .= Leader
            -- vote failed, need retry
            HalfVoteFailed -> undefined
            NetworkError -> undefined
        )
    Leader -> do
      res <- callAll @"peer" A
      undefined

r1 :: IO ()
r1 = do
  tr <- newTimeout 5
  void $
    runWithPeers @"peer" (NodeID 1) $
      runMetric @Counter $
        runState (CoreState Follower tr) $
          runError @ProcessError $
            t1
