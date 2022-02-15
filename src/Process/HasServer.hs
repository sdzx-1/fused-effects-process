{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes, ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}

module Process.HasServer where
import           Control.Carrier.Error.Either   ( Algebra
                                                , Has
                                                )
import           Control.Carrier.Reader         ( Algebra
                                                , Has
                                                , Reader
                                                , ReaderC(..)
                                                , ask
                                                , runReader
                                                )
import           Control.Concurrent             (
                                                --  Chan
                                                  MVar
                                                -- , newChan
                                                , newEmptyMVar
                                                -- , readChan
                                                , takeMVar
                                                -- , writeChan
                                                )
import           Control.Concurrent.MVar        ( putMVar )
import           Control.Concurrent.STM         ( TChan
                                                , atomically
                                                , readTChan
                                                , writeTChan
                                                )
import           Control.Effect.Labelled        ( type (:+:)(..)
                                                , Algebra(..)
                                                , Has
                                                , HasLabelled
                                                , Labelled
                                                , runLabelled
                                                , sendLabelled
                                                )
import           Control.Monad                  ( forever )
import           Control.Monad.IO.Class         ( MonadIO(..) )
import           Data.Kind                      ( Constraint
                                                , Type
                                                )
import           GHC.TypeLits                   ( ErrorMessage
                                                    ( (:<>:)
                                                    , ShowType
                                                    , Text
                                                    )
                                                , Symbol
                                                , TypeError
                                                )
import           Process.Type                   ( Elem
                                                , Elems
                                                , Some(..)
                                                , Sum
                                                , ToList
                                                , ToSig
                                                , inject, PV(..)
                                                )
import           Unsafe.Coerce                  ( unsafeCoerce )

type HasServer (serverName :: Symbol) s ts sig m
    = ( Elems serverName ts (ToList s)
      , HasLabelled serverName (Request s ts) sig m
      )

type Request :: (Type -> Type)
            -> [Type]
            -> (Type -> Type)
            -> Type
            -> Type
data Request s ts m a where
    SendReq ::(ToSig t s) =>t -> Request s ts m ()

sendReq
    :: forall serverName s ts sig m t
     . ( Elem serverName t ts
       , ToSig t s
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => t
    -> m ()
sendReq t = sendLabelled @serverName (SendReq t)

call
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => (PV b -> e)
    -> m b
call f = do
    -- liftIO $ putStrLn "send call, wait response"
    mvar <- liftIO newEmptyMVar
    sendReq @serverName (f $ PV mvar)
    liftIO $ takeMVar mvar

cast
    :: forall serverName s ts sig m e b
     . ( Elem serverName e ts
       , ToSig e s
       , MonadIO m
       , HasLabelled (serverName :: Symbol) (Request s ts) sig m
       )
    => e
    -> m ()
cast f = do
    -- liftIO $ putStrLn "send cast"
    sendReq @serverName f

newtype RequestC s ts m a = RequestC { unRequestC :: ReaderC (TChan (Sum s ts)) m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: sig) (RequestC s ts m) where
    alg hdl sig ctx = RequestC $ ReaderC $ \c -> case sig of
        L (SendReq t) -> do
            liftIO $ atomically $ writeTChan c (inject t)
            pure ctx
        R signa -> alg (runReader c . unRequestC . hdl) signa ctx
-- client
runWithServer
    :: forall serverName s ts m a
     . TChan (Some s)
    -> Labelled (serverName :: Symbol) (RequestC s ts) m a
    -> m a
runWithServer chan f =
    runReader (unsafeCoerce chan) $ unRequestC $ runLabelled f
