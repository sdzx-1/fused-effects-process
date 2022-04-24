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

module Raft.Type where

import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Typeable as T
import Optics (makeLenses)
import Process.HasPeerGroup (NodeId, RespVal)
import Process.Metric
  ( Default (..),
    K (..),
    NameVector (..),
    Vlength (..),
  )
import Process.TH (fromList, mkMetric, mkSigAndClass)
import Process.Timer (Timeout)
import Process.Type (ToList, ToSig (..))

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
  [ ''AppendEntries,
    ''RequestVote
  ]

data Role
  = Follower
  | Candidate
  | Leader
  deriving (Show, Eq, Ord)

data Control
  = TimeoutError
  | HalfVoteFailed
  | HalfVoteSuccess
  | NetworkError
  | StrangeError
  deriving (Show, Eq, Ord)

data CoreState = CoreState
  { _nodeRole :: Role,
    _timeout :: Timeout
  }
  deriving (Show)

makeLenses ''CoreState

mkMetric
  "Counter"
  [ "all_cycle",
    "all_leader_timeout",
    "all_vote",
    "all_network_error"
  ]
