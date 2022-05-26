module Process.TChan
  ( TChan (..),
    writeTChan,
    readTChan,
    newTChanIO,
    flushTQueue,
    tryReadTQueue,
    getChanSize,
  )
where

import qualified Control.Concurrent.STM as T
import Control.Concurrent.STM.TQueue
  ( newTQueue,
    readTQueue,
    writeTQueue,
  )

data TChan a = TChan {-# UNPACK #-} !(T.TVar Int) {-# UNPACK #-} !(T.TQueue a)

writeTChan :: TChan a -> a -> T.STM ()
writeTChan (TChan tv tc) a = do
  writeTQueue tc a
  T.modifyTVar' tv (+ 1)
{-# INLINE writeTChan #-}

newTChanIO :: IO (TChan a)
newTChanIO = T.atomically $ TChan <$> T.newTVar 0 <*> newTQueue
{-# INLINE newTChanIO #-}

readTChan :: TChan a -> T.STM a
readTChan (TChan tv tc) = do
  v <- readTQueue tc
  T.modifyTVar' tv (\x -> x - 1)
  pure v
{-# INLINE readTChan #-}

flushTQueue :: TChan a -> T.STM [a]
flushTQueue (TChan tv tc) = do
  vals <- T.flushTQueue tc
  T.modifyTVar' tv (const 0)
  pure vals
{-# INLINE flushTQueue #-}

tryReadTQueue :: TChan a -> T.STM (Maybe a)
tryReadTQueue (TChan tv tc) = do
  val <- T.tryReadTQueue tc
  case val of
    Nothing -> do
      pure Nothing
    Just v -> do
      T.modifyTVar' tv (\x -> x - 1)
      pure $ Just v
{-# INLINE tryReadTQueue #-}

getChanSize :: TChan a -> IO Int
getChanSize (TChan tv _) = T.atomically $ T.readTVar tv
{-# INLINE getChanSize #-}
