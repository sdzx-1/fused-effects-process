{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Raft.Server where

import Control.Algebra (Has, type (:+:))
import Control.Applicative (Alternative ((<|>)))
import Control.Carrier.Error.Either
  ( Error,
    catchError,
    runError,
    throwError,
  )
import Control.Carrier.State.Strict
  ( State,
    modify,
    runState,
  )
import Control.Concurrent.STM (atomically)
import Control.Effect.Optics (use, (.=))
import Control.Monad (forM_, forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Typeable as T
import Process.HasPeerGroup
  ( HasPeerGroup,
    NodeId (NodeId),
    callAll,
    getChan,
    runWithPeers,
  )
import Process.Metric (Metric, inc, putVal, runMetric)
import Process.TChan (TChan, readTChan)
import Process.Timer (Timeout, newTimeout, waitTimeout)
import Process.Type (Some (..))
import Process.Util
import Raft.Metric
import Raft.Type
  ( AppendEntries (AppendEntries),
    Control (StrangeError, TimeoutError),
    CoreState (CoreState),
    Entries (..),
    Machine (..),
    MapCommand,
    RequestVote (RequestVote),
    Role (Candidate, Follower, Leader),
    SigRPC (..),
    Vote (..),
    initPersistentState,
    initVolatileState,
    nodeRole,
    timeout,
  )

readMessageChanWithTimeout ::
  forall f sig m.
  (MonadIO m, Has (Error Control) sig m) =>
  Timeout ->
  TChan (Some f) ->
  (forall s. f s %1 -> m ()) ->
  m ()
readMessageChanWithTimeout to tc f = do
  v <- liftIO $ atomically $ waitTimeout to <|> Just <$> readTChan tc
  case v of
    Nothing -> throwError TimeoutError
    Just (Some val) -> f val

t1 ::
  forall command state sig m.
  ( MonadIO m,
    Has (Metric Counter) sig m, -- metric
    T.Typeable command,
    Machine command state, -- machine
    Has (State state) sig m,
    HasPeerGroup "peer" SigRPC '[AppendEntries, RequestVote] sig m, -- peer rpc, message chan
    Has (State (CoreState command) :+: Error Control) sig m -- raft core state, control flow
  ) =>
  m ()
t1 = forever $ do
  inc all_cycle
  use @(CoreState command) nodeRole >>= \case
    Follower -> do
      (tc, timer) <- (,) <$> getChan @"peer" <*> use @(CoreState command) timeout
      catchError @Control
        ( readMessageChanWithTimeout timer tc \case
            SigRPC1 (AppendEntries ents rsp) -> do
              withResp
                rsp
                $ do
                  -- update machine
                  forM_ (entries ents) $ \comm -> do
                    case T.cast comm :: Maybe command of
                      Nothing -> throwError StrangeError
                      Just command -> modify @state (applyCommand command)
                  pure undefined
            SigRPC2 (RequestVote _ rsp) -> undefined rsp
        )
        ( \case
            TimeoutError -> do
              inc all_leader_timeout
              -- timeout, need new leader select
              -- change role to Candidate
              (.=) @(CoreState command) nodeRole Candidate
              undefined
            _ -> undefined
        )
    Candidate -> do
      callAll @"peer" $
        RequestVote $
          Vote { vterm = 0, candidateId = NodeId 1,
              lastLogIndex = 0,
              lastLogTerm = 0
            }
      -- timer <- liftIO $ newTimeout 2
      -- halfVote <- (`div` 2) <$> peerSize @"peer"

      -- clean all_vote
      putVal all_vote 0
    -- catchError @Control
    --   ( forM_ [1 .. length cs + 1] $ \index -> do
    --       when (index == length cs + 1) (throwError HalfVoteFailed)
    --       whenM ((>= halfVote) <$> getVal all_vote) (throwError HalfVoteSuccess)
    --       res <- liftIO $ atomically $ waitTimeout timer <|> (Just <$> waitTMVars cs)
    --       case res of
    --         Nothing -> do
    --           -- cluster timeout ?? maybe network error
    --           inc all_network_error
    --           throwError NetworkError
    --         Just (_nid, bool) -> do
    --           -- vote true, inc all_votes
    --           when bool (inc all_vote)
    --   )
    --   ( \case
    --       -- vote sucess, set role to leader
    --       HalfVoteSuccess -> nodeRole .= Leader
    --       -- vote failed, need retry
    --       HalfVoteFailed -> undefined
    --       NetworkError -> undefined
    --       _ -> undefined
    --   )
    Leader -> do
      callAll @"peer" $
        AppendEntries @command @state $
          Entries
            { eterm = 0,
              leaderId = NodeId 1,
              preLogIndex = 0,
              prevLogTerm = 0,
              entries = [],
              leaderCommit = 0
            }

      undefined

r1 :: IO ()
r1 = do
  tr <- newTimeout 5
  void $
    runWithPeers @"peer" (NodeId 1) $
      runMetric @Counter $
        runState @(CoreState MapCommand)
          ( CoreState
              Follower
              tr
              initPersistentState
              initVolatileState
              Nothing
          )
          $ runState @(Map Int Int) Map.empty $
            runError @Control $
              t1 @MapCommand @(Map Int Int)
