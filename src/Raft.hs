{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
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
{-# OPTIONS_GHC -Wall #-}

module Raft where

import Control.Algebra
import Control.Applicative
import Control.Carrier.Error.Either
import Control.Carrier.State.Strict
import Control.Concurrent.STM (atomically)
import Control.Effect.Optics
import Control.Monad
import Control.Monad.IO.Class
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Typeable as T
import Optics (makeLenses)
import Process.HasPeerGroup
import Process.Metric
import Process.TChan
import Process.TH
import Process.Timer
import Process.Type (Some (..), ToList, ToSig (..))

whenM :: Monad m => m Bool -> m () -> m ()
whenM b m = do
  bool <- b
  when bool m

data VoteExample where
  VoteExample :: RespVal Bool %1 -> VoteExample

newtype Term = Term Int deriving (Show, Eq, Ord)

type Index = Int

-- machine class

class Machine command state where
  applyCommand :: command -> state -> state

---------- command example ----------------
type Key = Int

type Val = Int

data MapCommand = EmptyMap | Insert Key Val | Delete Key
  deriving (Show, Eq, T.Typeable)

instance Machine MapCommand (Map Int Int) where
  applyCommand comm machine =
    case comm of
      EmptyMap -> Map.empty
      Insert k v -> Map.insert k v machine
      Delete k -> Map.delete k machine

-------------------------------------------

data PersistentState command = PersistentState
  { currentTerm :: Term,
    votedFor :: Maybe NodeId,
    logs :: [(Term, Index, command)]
  }

data VolatileState = VolatileState
  { commitIndex :: Index,
    lastApplied :: Index
  }

data LeaderVolatileState = LeaderVolatileState
  { nextIndexs :: Map NodeId Index,
    matchIndexs :: Map NodeId Index
  }

data Entries command = Entries
  { eterm :: Term,
    leaderId :: NodeId,
    preLogIndex :: Index,
    prevLogTerm :: Term,
    entries :: [command],
    leaderCommit :: Index
  }

data AppendEntries where
  AppendEntries ::
    ( Machine command state,
      T.Typeable command
    ) =>
    Entries command ->
    RespVal (Term, Bool) %1 ->
    AppendEntries

data Vote = Vote
  { vterm :: Term,
    candidateId :: NodeId,
    lastLogIndex :: Index,
    lastLogTerm :: Term
  }

data RequestVote where
  RequestVote :: Vote -> RespVal (Term, Bool) %1 -> RequestVote

mkSigAndClass
  "SigRPC"
  [ ''VoteExample,
    -------------
    ''AppendEntries,
    ''RequestVote
  ]

data Role = Follower | Candidate | Leader deriving (Show, Eq, Ord)

data Control
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
  forall f sig m.
  (MonadIO m, Has (Error Control) sig m) =>
  Timeout ->
  TChan (Some f) ->
  (forall s. f s %1 -> m ()) ->
  m ()
readMessageChanWithTimeout to tc f = do
  v <- liftIO $ atomically $ waitTimeout to <|> (Just <$> readTChan tc)
  case v of
    Nothing -> throwError TimeoutError
    Just (Some val) -> f val

mkMetric
  "Counter"
  [ "all_cycle",
    "all_leader_timeout",
    "all_vote",
    "all_network_error"
  ]

t1 ::
  forall command state sig m.
  ( MonadIO m,
    -- metric
    Has (Metric Counter) sig m,
    -- machine
    T.Typeable command,
    Machine command state,
    Has (State state) sig m,
    -- peer rpc, message chan
    HasPeerGroup "peer" SigRPC '[VoteExample] sig m,
    -- raft core state, control flow
    Has (State CoreState :+: Error Control) sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_cycle
  use nodeRole >>= \case
    Follower -> do
      (tc, timer) <- (,) <$> getChan @"peer" <*> use timeout
      catchError @Control
        ( readMessageChanWithTimeout timer tc \case
            SigRPC1 (VoteExample rsp) -> undefined rsp
            SigRPC2 (AppendEntries ents rsp) -> do
              withResp
                rsp
                ( do
                    -- update machine
                    forM_ (entries ents) $ \comm -> do
                      case T.cast comm :: Maybe command of
                        Nothing -> error "interal error"
                        Just command -> modify @state (applyCommand command)
                    pure undefined
                )
            SigRPC3 (RequestVote _ rsp) -> undefined rsp
        )
        ( \case
            TimeoutError -> do
              inc all_leader_timeout
              -- timeout, need new leader select
              -- change role to Candidate
              nodeRole .= Candidate
              undefined
            _ -> undefined
        )
    Candidate -> do
      cs <- callAll @"peer" VoteExample
      timer <- liftIO $ newTimeout 2
      halfVote <- (`div` 2) <$> peerSize @"peer"

      -- clean all_vote
      putVal all_vote 0
      catchError @Control
        ( forM_ [1 .. length cs + 1] $ \index -> do
            when (index == length cs + 1) (throwError HalfVoteFailed)
            whenM ((>= halfVote) <$> getVal all_vote) (throwError HalfVoteSuccess)
            res <- liftIO $ atomically $ waitTimeout timer <|> (Just <$> waitTMVars cs)
            case res of
              Nothing -> do
                -- cluster timeout ?? maybe network error
                inc all_network_error
                throwError NetworkError
              Just (_nid, bool) -> do
                -- vote true, inc all_votes
                when bool (inc all_vote)
        )
        ( \case
            -- vote sucess, set role to leader
            HalfVoteSuccess -> nodeRole .= Leader
            -- vote failed, need retry
            HalfVoteFailed -> undefined
            NetworkError -> undefined
            _ -> undefined
        )
    Leader -> do
      undefined

r1 :: IO ()
r1 = do
  tr <- newTimeout 5
  void $
    runWithPeers @"peer" (NodeId 1) $
      runMetric @Counter $
        runState (CoreState Follower tr) $
          runState @(Map Int Int) Map.empty $
            runError @Control $
              t1 @MapCommand @(Map Int Int)
