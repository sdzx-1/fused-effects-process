{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE NamedFieldPuns #-}

module Process.HasWorkGroup where
import           Control.Algebra                ( type (:+:)(..)
                                                , Algebra(..)
                                                , Has
                                                , send
                                                )
import           Control.Carrier.Reader         ( Algebra
                                                , Has
                                                , Reader
                                                , ReaderC(..)
                                                , ask
                                                , runReader
                                                )
import           Control.Carrier.State.Strict   ( Algebra
                                                , Has
                                                , StateC(..)
                                                , evalState
                                                , get
                                                , put, gets
                                                )
import           Control.Concurrent             ( MVar
                                                , forkIO
                                                , newEmptyMVar
                                                , putMVar
                                                , takeMVar, newMVar
                                                )
import           Control.Concurrent.STM         ( TChan
                                                , atomically
                                                , isEmptyTChan
                                                , newTChanIO
                                                , readTChan
                                                , writeTChan, TVar, newTVarIO, writeTVar, readTVar
                                                )
import           Control.Effect.Labelled        ( type (:+:)(..)
                                                , Algebra(..)
                                                , Has
                                                , HasLabelled
                                                , Labelled
                                                , LabelledMember
                                                , runLabelled
                                                , sendLabelled
                                                )
import           Control.Monad                  ( forM
                                                , forM_
                                                , forever
                                                , replicateM
                                                , void
                                                )
import           Control.Monad.IO.Class         ( MonadIO(..) )
import           Data.IntMap                    ( IntMap )
import qualified Data.IntMap                   as IntMap
import           Data.Kind                      ( Type )
import           Data.Traversable               ( for )
import           GHC.TypeLits                   ( Symbol )
import           Process.Type                   ( Elem
                                                , Elems
                                                , Fork(Fork)
                                                , Some(..)
                                                , Sum
                                                , ToList
                                                , ToSig
                                                , inject
                                                , RespVal(..), ProcessState(..), Result(..)
                                                )
import           Unsafe.Coerce                  ( unsafeCoerce )
import           Control.Exception
import Data.Time (getCurrentTime)

type HasWorkGroup (serverName :: Symbol) s ts sig m
    = ( Elems serverName ts (ToList s)
      , Has (Manager s) sig m
      , HasLabelled serverName (Request s ts) sig m
      )

type Request :: (Type -> Type)
            -> [Type]
            -> (Type -> Type)
            -> Type
            -> Type
data Request s ts m a where
    SendReq ::(ToSig t s) =>Int -> t -> Request s ts m ()
    SendAllCall ::(ToSig t s) => (RespVal b -> t) -> Request s ts m [MVar b]
    SendAllCast ::(ToSig t s) => t -> Request s ts m ()

type Manager :: (Type -> Type) -> (Type -> Type) -> Type -> Type
data Manager s m a where
    CreateWorker ::(TChan (Some s) -> IO ()) -> Manager s m ()
    DeleteWorker ::Int -> Manager s m ()

sendReq
    :: forall (serverName :: Symbol) s ts sig m t
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       )
    => Int
    -> t
    -> m ()
sendReq i t = sendLabelled @serverName (SendReq i t)

sendAllCall
    :: forall (serverName :: Symbol) s ts sig m t b
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       )
    => (RespVal b -> t)
    -> m [MVar b]
sendAllCall t = sendLabelled @serverName (SendAllCall t)

sendAllCast
    :: forall (serverName :: Symbol) s ts sig m t b
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       )
    => t
    -> m ()
sendAllCast t = sendLabelled @serverName (SendAllCast t)

callById
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => Int
    -> (MVar b -> e)
    -> m b
callById i f = do
    mvar <- liftIO newEmptyMVar
    sendReq @serverName i (f mvar)
    liftIO $ takeMVar mvar

callAll
    :: forall (serverName :: Symbol) s ts sig m t b
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       , MonadIO m
       )
    => (RespVal b -> t)
    -> m [b]
callAll t = do
    vs <- sendLabelled @serverName (SendAllCall t)
    mapM (liftIO . takeMVar) vs

mcall
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => [Int]
    -> (MVar b -> e)
    -> m [b]
mcall is f = do
    for is $ \idx -> do
        mvar <- liftIO newEmptyMVar
        v    <- sendReq @serverName idx (f mvar)
        liftIO $ takeMVar mvar

castById
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => Int
    -> e
    -> m ()
castById i f = do
    sendReq @serverName i f

castAll
    :: forall (serverName :: Symbol) s ts sig m t b
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled serverName (Request s ts) sig m
       , MonadIO m
       )
    => t
    -> m ()
castAll t = sendLabelled @serverName (SendAllCast t)

mcast
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , HasLabelled serverName (Request s ts) sig m
       , MonadIO m
       )
    => [Int]
    -> e
    -> m ()
mcast is f = mapM_ (\x -> castById @serverName x f) is

createWorker
    :: forall s sig m a
     . (MonadIO m, Has (Manager s) sig m)
    => (TChan (Some s) -> IO ())
    -> m ()
createWorker fun = send (CreateWorker fun)

deleteChan
    :: forall s sig m a . (MonadIO m, Has (Manager s) sig m) => Int -> m ()
deleteChan i = send (DeleteWorker @s i)

data WorkGroupState s ts = WorkGroupState
    { workMap :: IntMap (ProcessState s ts)
    , counter :: Int
    , terminateMap :: TVar (IntMap (MVar Result))
    }

newtype RequestC s ts m a = RequestC { unRequestC :: StateC (WorkGroupState s ts) m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: Manager s :+: sig) (RequestC s ts m) where
    alg hdl sig ctx = RequestC $ case sig of
        L (SendReq i t) -> do
            wm <- gets @(WorkGroupState s ts) (workMap)
            case IntMap.lookup i wm of
                Nothing -> error "never happend.."
                Just ch -> do
                    liftIO $ atomically $ writeTChan (pChan ch) (inject t)
                    pure (() <$ ctx)

        L (SendAllCall t) -> do
            wm  <- gets @(WorkGroupState s ts) workMap
            mvs <- forM (IntMap.elems wm) $ \ch -> do
                mv <-  liftIO newEmptyMVar
                liftIO $ atomically $ writeTChan (pChan ch) (inject (t $ RespVal mv))
                pure mv
            pure (mvs <$ ctx)

        L (SendAllCast t) -> do
            wm <- gets @(WorkGroupState s ts) workMap
            IntMap.traverseWithKey
                (\_ ch -> liftIO $ atomically $ writeTChan (pChan ch) (inject t))
                wm
            pure ctx

        R (L (CreateWorker fun)) -> do

            -- init resource
            state@WorkGroupState { workMap, counter, terminateMap } <-
                get @(WorkGroupState s ts)
            chan <- liftIO newTChanIO
            tmv <- liftIO newEmptyMVar

            -- fork process
            tid <- liftIO $ forkIO $ do
                res <- try @SomeException $ fun chan
                tim <- getCurrentTime
                liftIO $ putMVar tmv (Result tim counter res)

            -- update resultMap
            liftIO $ atomically $ do
                im <- readTVar terminateMap
                writeTVar terminateMap (IntMap.insert counter tmv im) 

            -- update workMap
            let newcounter = counter + 1
                newmap     = IntMap.insert counter (ProcessState (unsafeCoerce chan) counter tid) workMap
            put state { workMap = newmap, counter = newcounter}

            pure ctx

        R ((L (DeleteWorker i))) -> do
            state@WorkGroupState { workMap, counter } <-
                get @(WorkGroupState s ts)
            put state { workMap = IntMap.delete i workMap }
            pure ctx

        R (R signa) -> alg (unRequestC . hdl) (R signa) ctx

initWorkGroupState :: TVar (IntMap (MVar Result)) -> WorkGroupState s ts
initWorkGroupState terminateMap = WorkGroupState { workMap = IntMap.empty
                                              , counter = 0
                                              , terminateMap = terminateMap 
                                              }

runWithWorkGroup
    :: forall serverName s ts m a
     . MonadIO m
    => Labelled (serverName :: Symbol) (RequestC s ts) m a
    -> m a
runWithWorkGroup f = do 
    tvar <- liftIO $ newTVarIO (IntMap.empty)
    evalState @(WorkGroupState s ts) (initWorkGroupState tvar)
        $ unRequestC
        $ runLabelled f
