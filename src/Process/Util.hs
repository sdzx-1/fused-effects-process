{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE GADTs #-}

module Process.Util where
import           Control.Algebra                ( type (:+:)
                                                , Has
                                                )
import           Control.Carrier.Reader         ( Has
                                                , Reader
                                                , ReaderC
                                                , ask
                                                , runReader
                                                )
import           Control.Concurrent             ( MVar
                                                , putMVar
                                                )
import           Control.Concurrent.STM         ( STM
                                                , TChan
                                                , atomically
                                                , isEmptyTChan
                                                , newTChanIO
                                                , orElse
                                                , readTChan
                                                )
import           Control.Monad                  ( forever )
import           Control.Monad.IO.Class         ( MonadIO(..) )
import           Process.HasWorkGroup           ( HasWorkGroup )
import           Process.Type                   ( Some(..), PV(..) )

type MessageChan f = Reader (TChan (Some f))

waitEither :: TChan f -> TChan l -> STM (Either f l)
waitEither left right =
    (Left <$> readTChan left) `orElse` (Right <$> readTChan right)

withResp :: (MonadIO m) => PV a %1 -> m a -> m ()
withResp (PV tmv) ma = do 
    val <- ma
    liftIO $ putMVar tmv val

-- server 
withMessageChan
    :: forall f es sig m
     . (Has (MessageChan f) sig m, MonadIO m)
    => (forall s . f s %1 -> m ())
    -> m ()
withMessageChan f = do
    tc     <- ask @(TChan (Some f))
    Some v <- liftIO $ atomically $ readTChan tc
    f v

runServerWithChan
    :: forall f m a . TChan (Some f) -> ReaderC (TChan (Some f)) m a -> m a
runServerWithChan = runReader

-- work
runWorkerWithChan
    :: forall f m a . TChan (Some f) -> ReaderC (TChan (Some f)) m a -> m a
runWorkerWithChan = runReader

withTwoMessageChan
    :: forall f g sig m
     . (Has (   MessageChan g
            :+: MessageChan f
            ) sig m, MonadIO m)
    => (forall s . f s -> m ())
    -> (forall s . g s -> m ())
    -> m ()
withTwoMessageChan f1 f2 = do
    f <- ask @(TChan (Some f))
    g <- ask @(TChan (Some g))
    liftIO (atomically (waitEither f g)) >>= \case
        Left  (Some so) -> f1 so
        Right (Some so) -> f2 so

data Three a b c = T1 a | T2 b | T3 c

waitTEither :: TChan f -> TChan g -> TChan l -> STM (Three f g l)
waitTEither t1 t2 t3 =
    (T1 <$> readTChan t1)
        `orElse` (T2 <$> readTChan t2)
        `orElse` (T3 <$> readTChan t3)

withThreeMessageChan
    :: forall f g l sig m
     . (Has (   MessageChan g
            :+: MessageChan f
            :+: MessageChan l
            ) sig m, MonadIO m)
    => (forall s . f s -> m ())
    -> (forall s . g s -> m ())
    -> (forall s . l s -> m ())
    -> m ()
withThreeMessageChan f1 f2 f3 = do
    f <- ask @(TChan (Some f))
    g <- ask @(TChan (Some g))
    l <- ask @(TChan (Some l))
    liftIO (atomically (waitTEither f g l)) >>= \case
        T1 (Some so) -> f1 so
        T2 (Some so) -> f2 so
        T3 (Some so) -> f3 so

newMessageChan :: forall f . IO (TChan (Some f))
newMessageChan = newTChanIO

-- inputOutput
--     :: forall input workName s ts sig m
--      . ( Has (MessageChan input) sig m
--        , HasWorkGroup workName s ts sig m
--        , MonadIO m
--        )
--     => m ()
--     -> (forall s . input s -> m ())
--     -> m ()
-- inputOutput fun fun1 = do
--     fun
--     forever $ withMessageChan @input fun1
