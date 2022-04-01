module Process.TChan
  ( TChan (..),
    writeTChan,
    readTChan,
    newTChanIO,
    getChanSize,
  )
where

import qualified Control.Concurrent.STM as T
import Control.Concurrent.STM.TQueue
  ( newTQueue,
    readTQueue,
    writeTQueue,
  )

data TChan a = TChan (T.TVar Int) (T.TQueue a)

writeTChan :: TChan a -> a -> T.STM ()
writeTChan (TChan tv tc) a = do
  writeTQueue tc a
  T.modifyTVar tv (+ 1)

newTChanIO :: IO (TChan a)
newTChanIO = T.atomically $ TChan <$> T.newTVar 0 <*> newTQueue

readTChan :: TChan a -> T.STM a
readTChan (TChan tv tc) = do
  v <- readTQueue tc
  T.modifyTVar' tv (\x -> x - 1)
  pure v

getChanSize :: TChan a -> IO Int
getChanSize (TChan tv _) = T.atomically $ T.readTVar tv
