{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}

module Process.HasPeerGroup where

-- a [b,c,d,e]  RPC
-- b [j,c,d]
-- c [a,b,d,e]
-- d [b,e]
-- e [a]

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TMVar
import Data.Kind
import Data.Map (Map)
import Process.Type
import Timer

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

data State

waitTMVars :: [(Int, TMVar a)] -> STM (Int, a)
waitTMVars tmvs =
  foldr (<|>) retry $
    map
      ( \(i, tmv) -> do
          mv <- takeTMVar tmv
          pure (i, mv)
      )
      tmvs

waitTimeout :: Timeout -> STM (Maybe a)
waitTimeout tmout = do
  tt <- readTimeout tmout
  case tt of
    TimeoutPending -> retry
    TimeoutFired -> pure Nothing
    TimeoutCancelled -> pure Nothing

fun :: IO ()
fun = do
  tmvs <- atomically $ do
    t1 <- newEmptyTMVar
    t2 <- newEmptyTMVar
    t3 <- newTMVar 3
    t4 <- newTMVar 4
    pure [(1, t1), (2, t2), (3, t3), (4, t4)]
  tmout <- newTimeout 1

  res <- atomically $ waitTimeout tmout <|> (Just <$> waitTMVars tmvs)
  case res of
    Nothing -> do
      print "timeout, reselete leader"
      undefined
    Just (i, val) -> do
      let nl = filter ((/=i) . fst) tmvs
      undefined

  print res
