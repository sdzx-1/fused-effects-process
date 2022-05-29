{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Process.Util where

import Control.Algebra
  ( Has,
    type (:+:),
  )
import Control.Carrier.HasPeer
import Control.Carrier.Reader
  ( Reader,
    ReaderC,
    ask,
    runReader,
  )
import Control.Concurrent.STM
  ( STM,
    atomically,
    orElse,
    putTMVar,
  )
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (MonadIO (..))
import Process.TChan (TChan, flushTQueue, newTChanIO, readTChan)
import Process.Type (RespVal (..), Some (..))

type MessageChan f = Reader (TChan (Some f))

waitEither :: TChan f -> TChan l -> STM (Either f l)
waitEither left right =
  (Left <$> readTChan left) `orElse` (Right <$> readTChan right)
{-# INLINE waitEither #-}

withResp :: (MonadIO m) => RespVal a %1 -> m a -> m ()
withResp (RespVal tmv) ma = do
  val <- ma
  liftIO $ atomically $ putTMVar tmv val
{-# INLINE withResp #-}

handleFlushMsgs ::
  forall f sig m.
  (Has (MessageChan f) sig m, MonadIO m) =>
  (forall s. f s %1 -> m ()) ->
  m ()
handleFlushMsgs f = do
  tc <- ask @(TChan (Some f))
  vals <- liftIO $ atomically $ flushTQueue tc
  forM_ vals $ \(Some v) -> f v
{-# INLINE handleFlushMsgs #-}

-- server
withMessageChan ::
  forall f sig m.
  (Has (MessageChan f) sig m, MonadIO m) =>
  (forall s. f s %1 -> m ()) ->
  m ()
withMessageChan f = do
  tc <- ask @(TChan (Some f))
  Some v <- liftIO $ atomically $ readTChan tc
  f v
{-# INLINE withMessageChan #-}

readMessageChan ::
  forall f m.
  (MonadIO m) =>
  TChan (Some f) ->
  (forall s. f s %1 -> m ()) ->
  m ()
readMessageChan tc f = do
  Some v <- liftIO $ atomically $ readTChan tc
  f v
{-# INLINE readMessageChan #-}

runServerWithChan ::
  forall f m a. TChan (Some f) -> ReaderC (TChan (Some f)) m a -> m a
runServerWithChan = runReader
{-# INLINE runServerWithChan #-}

-- work
runWorkerWithChan ::
  forall f m a. TChan (Some f) -> ReaderC (TChan (Some f)) m a -> m a
runWorkerWithChan = runReader
{-# INLINE runWorkerWithChan #-}

withTwoMessageChan ::
  forall f g sig m.
  ( Has
      ( MessageChan g
          :+: MessageChan f
      )
      sig
      m,
    MonadIO m
  ) =>
  (forall s. f s %1 -> m ()) ->
  (forall s. g s %1 -> m ()) ->
  m ()
withTwoMessageChan f1 f2 = do
  f <- ask @(TChan (Some f))
  g <- ask @(TChan (Some g))
  liftIO (atomically (waitEither f g)) >>= \case
    Left (Some so) -> f1 so
    Right (Some so) -> f2 so
{-# INLINE withTwoMessageChan #-}

data Three a b c = T1 a | T2 b | T3 c

waitTEither :: TChan f -> TChan g -> TChan l -> STM (Three f g l)
waitTEither t1 t2 t3 =
  (T1 <$> readTChan t1)
    `orElse` (T2 <$> readTChan t2)
    `orElse` (T3 <$> readTChan t3)
{-# INLINE waitTEither #-}

withThreeMessageChan ::
  forall f g l sig m.
  ( Has
      ( MessageChan g
          :+: MessageChan f
          :+: MessageChan l
      )
      sig
      m,
    MonadIO m
  ) =>
  (forall s. f s %1 -> m ()) ->
  (forall s. g s %1 -> m ()) ->
  (forall s. l s %1 -> m ()) ->
  m ()
withThreeMessageChan f1 f2 f3 = do
  f <- ask @(TChan (Some f))
  g <- ask @(TChan (Some g))
  l <- ask @(TChan (Some l))
  liftIO (atomically (waitTEither f g l)) >>= \case
    T1 (Some so) -> f1 so
    T2 (Some so) -> f2 so
    T3 (Some so) -> f3 so
{-# INLINE withThreeMessageChan #-}

newMessageChan :: forall f. IO (TChan (Some f))
newMessageChan = newTChanIO
{-# INLINE newMessageChan #-}

whenM :: Monad m => m Bool -> m () -> m ()
whenM b m = do
  bool <- b
  when bool m
{-# INLINE whenM #-}

handleMsg ::
  forall peerName s ts sig m.
  ( MonadIO m,
    HasPeer peerName s ts sig m
  ) =>
  (forall s1. s s1 %1 -> m ()) ->
  m ()
handleMsg f = do
  chan <- getChan @peerName
  Some tc <- liftIO $ atomically $ readTChan chan
  f tc
{-# INLINE handleMsg #-}

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
