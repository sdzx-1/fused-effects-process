{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}

module Process.HasPeerGroup where

-- a [b,c,d,e]  RPC
-- b [j,c,d]
-- c [a,b,d,e]
-- d [b,e]
-- e [a]

import Control.Concurrent
import Control.Concurrent.STM (TChan)
import Data.Kind
import Data.Map (Map)
import Process.Type

newtype NodeID = NodeID Int

data NodeState s ts = NodeState
  { nodeId :: NodeID,
    peers :: Map NodeID (TChan (Sum s ts))
  }

---------------------------------------- api
-- peerJoin
-- peerLeave
-- callPeer :: NodeID -> Message -> m RespVal
-- callPeers :: Message -> m [RespVal]
-- castPeer :: NodeID -> Message -> m ()
-- castPeers :: Message -> m ()

-- type PeerMethod :: (Type -> Type) -> (Type -> Type) -> (Type -> Type) -> Type -> Type
-- data PeerMethod s ts m a where
--   Join :: NodeID -> TChan (Sum s ts) -> PeerMethod s ts m a
--   Leave :: NodeID -> PeerMethod s ts m a

data SendMessage s ts m a where
  SendMessage :: (ToSig t s) => Int -> t -> SendMessage s ts m ()
  SendAllCall :: (ToSig t s) => (RespVal b -> t) -> SendMessage s ts m [(Int, MVar b)]
  SendAllCast :: (ToSig t s) => t -> SendMessage s ts m ()
