{-# LANGUAGE AllowAmbiguousTypes #-}
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
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.HasWorkGroup where

import Control.Algebra
  ( Algebra (..),
    Has,
    send,
    type (:+:) (..),
  )
import Control.Carrier.State.Strict
  ( StateC (..),
    evalState,
    get,
    gets,
    put,
  )
import Control.Concurrent
  ( MVar,
    forkIO,
    killThread,
    newEmptyMVar,
    putMVar,
    takeMVar,
  )
import Control.Concurrent.STM
  ( TMVar,
    TVar,
    atomically,
    modifyTVar',
    newEmptyTMVarIO,
    newTVarIO,
    readTVar,
    takeTMVar,
    writeTVar,
  )
import Control.Effect.Labelled
  ( HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
  )
import Control.Exception
import Control.Monad
  ( forM,
  )
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind (Type)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Time (getCurrentTime)
import Data.Traversable (for)
import GHC.TypeLits (Symbol)
import Process.TChan
  ( TChan,
    newTChanIO,
    writeTChan,
  )
import Process.Type
  ( Elem,
    Elems,
    NodeId (NodeId),
    ProcessInfo,
    ProcessState (..),
    RespVal (..),
    Result (..),
    Some (..),
    ToList,
    ToSig,
    addOne,
    inject,
    state2info,
  )
import System.Timeout (timeout)
import Unsafe.Coerce (unsafeCoerce)

type HasWorkGroup (serverName :: Symbol) s ts sig m =
  ( Elems serverName ts (ToList s),
    Has (Manager s) sig m,
    HasLabelled serverName (Request s ts) sig m
  )

type Request ::
  (Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  Type ->
  Type
data Request s ts m a where
  SendReq :: (ToSig t s) => NodeId -> t -> Request s ts m ()
  SendAllCall :: (ToSig t s) => (RespVal b -> t) -> Request s ts m [(NodeId, TMVar b)]
  SendAllCast :: (ToSig t s) => t -> Request s ts m ()

type Manager :: (Type -> Type) -> (Type -> Type) -> Type -> Type
data Manager s m a where
  CreateWorker :: (NodeId -> TChan (Some s) -> IO ()) -> Manager s m ()
  DeleteChannel :: NodeId -> Manager s m ()
  ClearTVar :: NodeId -> Manager s m ()
  KillWorker :: NodeId -> Manager s m ()
  GetAllWorker :: Manager s m [NodeId]
  GetAllInfo :: Manager s m [ProcessInfo]

sendReq ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  NodeId ->
  t ->
  m ()
sendReq i t = sendLabelled @serverName (SendReq i t)
{-# INLINE sendReq #-}

sendAllCall ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  (RespVal b -> t) ->
  m [(NodeId, TMVar b)]
sendAllCall t = sendLabelled @serverName (SendAllCall t)
{-# INLINE sendAllCall #-}

sendAllCast ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  t ->
  m ()
sendAllCast t = sendLabelled @serverName (SendAllCast t)
{-# INLINE sendAllCast #-}

callById ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  NodeId ->
  (RespVal b -> e) ->
  m b
callById i f = do
  mvar <- liftIO newEmptyTMVarIO
  sendReq @serverName i (f $ RespVal mvar)
  liftIO $ atomically $ takeTMVar mvar
{-# INLINE callById #-}

data Reset
  = ResetWorker [NodeId]
  | ResetWork [IO ()]
  | NoReset

instance Show Reset where
  show = \case
    ResetWorker ns -> "left worker: " ++ show (length ns)
    ResetWork ios -> "left work: " ++ show (length ios)
    NoReset -> "no left"

-- | send works to it workers
sendWorks ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m,
    Has (Manager s) sig m
  ) =>
  [IO ()] ->
  (IO () -> RespVal () -> e) ->
  m ([(NodeId, TMVar ())], Reset)
sendWorks works f = do
  workers <- getAllWorker @s
  let allWork = length works
      allWorker = length workers
      (workPair, rest) = case compare allWorker allWork of
        EQ -> (zip workers works, NoReset)
        GT -> let (wera, werb) = splitAt allWork workers in (zip wera works, ResetWorker werb)
        LT -> let (wa, wb) = splitAt allWorker works in (zip workers wa, ResetWork wb)
  t <- forM workPair $ \(wid, work) -> do
    mvar <- liftIO newEmptyTMVarIO
    sendReq @serverName wid (f work $ RespVal mvar)
    pure (wid, mvar)
  pure (t, rest)
{-# INLINE sendWorks #-}

callAll ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  (RespVal b -> t) ->
  m [b]
callAll t = do
  vs <- sendLabelled @serverName (SendAllCall t)
  mapM (liftIO . atomically . takeTMVar . snd) vs
{-# INLINE callAll #-}

timeoutCallAll ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  Int ->
  (RespVal b -> t) ->
  m (Maybe [b])
timeoutCallAll tot t = do
  vs <- sendLabelled @serverName (SendAllCall t)
  liftIO $ timeout tot $ mapM (atomically . takeTMVar . snd) vs
{-# INLINE timeoutCallAll #-}

mcall ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  [NodeId] ->
  (MVar b -> e) ->
  m [b]
mcall is f = do
  for is $ \idx -> do
    mvar <- liftIO newEmptyMVar
    _ <- sendReq @serverName idx (f mvar)
    liftIO $ takeMVar mvar
{-# INLINE mcall #-}

castById ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  NodeId ->
  e ->
  m ()
castById i f = do
  sendReq @serverName i f
{-# INLINE castById #-}

castAll ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  t ->
  m ()
castAll t = sendLabelled @serverName (SendAllCast t)
{-# INLINE castAll #-}

mcast ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  [NodeId] ->
  e ->
  m ()
mcast is f = mapM_ (\x -> castById @serverName x f) is
{-# INLINE mcast #-}

createWorker ::
  forall s sig m.
  (MonadIO m, Has (Manager s) sig m) =>
  (NodeId -> TChan (Some s) -> IO ()) ->
  m ()
createWorker fun = send (CreateWorker fun)
{-# INLINE createWorker #-}

deleteChan ::
  forall s sig m. (MonadIO m, Has (Manager s) sig m) => NodeId -> m ()
deleteChan i = send (DeleteChannel @s i)
{-# INLINE deleteChan #-}

clearTVar ::
  forall s sig m. (MonadIO m, Has (Manager s) sig m) => NodeId -> m ()
clearTVar i = send (ClearTVar @s i)
{-# INLINE clearTVar #-}

killWorker ::
  forall s sig m. (MonadIO m, Has (Manager s) sig m) => NodeId -> m ()
killWorker i = send (KillWorker @s i)
{-# INLINE killWorker #-}

getAllWorker ::
  forall s sig m. (MonadIO m, Has (Manager s) sig m) => m [NodeId]
getAllWorker = send (GetAllWorker @s)
{-# INLINE getAllWorker #-}

getAllInfo ::
  forall s sig m. (MonadIO m, Has (Manager s) sig m) => m [ProcessInfo]
getAllInfo = send (GetAllInfo @s)
{-# INLINE getAllInfo #-}

data WorkGroupState s ts = WorkGroupState
  { workMap :: Map NodeId (ProcessState s ts),
    counter :: NodeId,
    terminateMap :: TVar (Map NodeId (MVar Result))
  }

newtype RequestC s ts m a = RequestC {unRequestC :: StateC (WorkGroupState s ts) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: Manager s :+: sig) (RequestC s ts m) where
  alg hdl sig ctx = RequestC $ case sig of
    L (SendReq i t) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      case Map.lookup i wm of
        Nothing -> do
          liftIO $ print $ "not found pid: " ++ show i
          pure ctx
        Just ch -> do
          liftIO $ atomically $ writeTChan (pChan ch) (inject t)
          pure ctx
    L (SendAllCall t) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      mvs <- forM (Map.toList wm) $ \(idx, ch) -> do
        mv <- liftIO newEmptyTMVarIO
        liftIO $ atomically $ writeTChan (pChan ch) (inject (t $ RespVal mv))
        pure (idx, mv)
      pure (mvs <$ ctx)
    L (SendAllCast t) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      Map.traverseWithKey
        (\_ ch -> liftIO $ atomically $ writeTChan (pChan ch) (inject t))
        wm
      pure ctx
    R (L (CreateWorker fun)) -> do
      -- init resource
      state@WorkGroupState {workMap, counter, terminateMap} <-
        get @(WorkGroupState s ts)
      chan <- liftIO newTChanIO
      tmv <- liftIO newEmptyMVar

      -- fork process
      tid <- liftIO $
        forkIO $ do
          res <- try @SomeException $ fun counter chan
          tim <- getCurrentTime
          liftIO $ putMVar tmv (Result tim counter res)

      -- update resultMap
      liftIO $
        atomically $ do
          im <- readTVar terminateMap
          writeTVar terminateMap (Map.insert counter tmv im)

      -- update workMap
      let newcounter = addOne counter
          newmap = Map.insert counter (ProcessState (unsafeCoerce chan) counter tid) workMap
      put state {workMap = newmap, counter = newcounter}

      pure ctx

    -- delete work chann
    R ((L (DeleteChannel i))) -> do
      state@WorkGroupState {workMap} <-
        get @(WorkGroupState s ts)
      put state {workMap = Map.delete i workMap}
      pure ctx

    -- remove tvar where id is i
    R (L (ClearTVar i)) -> do
      WorkGroupState {terminateMap} <-
        get @(WorkGroupState s ts)
      liftIO $
        atomically $
          modifyTVar' terminateMap (Map.delete i)
      pure ctx
    -- kill a worker
    R (L (KillWorker i)) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      case Map.lookup i wm of
        Nothing -> do
          liftIO $ print $ "not found pid: " ++ show i
          pure ctx
        Just ProcessState {tid} -> do
          liftIO $ killThread tid
          pure ctx
    R (L GetAllWorker) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      pure (Map.keys wm <$ ctx)
    R (L GetAllInfo) -> do
      wm <- gets @(WorkGroupState s ts) workMap
      ls <- liftIO $ Map.traverseWithKey (\_ ch -> state2info ch) wm
      pure (Map.elems ls <$ ctx)
    R (R signa) -> alg (unRequestC . hdl) (R signa) ctx
  {-# INLINE alg #-}

initWorkGroupState :: TVar (Map NodeId (MVar Result)) -> WorkGroupState s ts
initWorkGroupState terminateMap =
  WorkGroupState
    { workMap = Map.empty,
      counter = NodeId 0,
      terminateMap = terminateMap
    }
{-# INLINE initWorkGroupState #-}

runWithWorkGroup ::
  forall serverName s ts m a.
  MonadIO m =>
  Labelled (serverName :: Symbol) (RequestC s ts) m a ->
  m a
runWithWorkGroup f = do
  tvar <- liftIO $ newTVarIO Map.empty
  evalState @(WorkGroupState s ts) (initWorkGroupState tvar) $
    unRequestC $
      runLabelled f
{-# INLINE runWithWorkGroup #-}

runWithWorkGroup' ::
  forall serverName s ts m a.
  MonadIO m =>
  TVar (Map NodeId (MVar Result)) ->
  Labelled (serverName :: Symbol) (RequestC s ts) m a ->
  m a
runWithWorkGroup' tvar f = do
  evalState @(WorkGroupState s ts) (initWorkGroupState tvar) $
    unRequestC $
      runLabelled f
{-# INLINE runWithWorkGroup' #-}
