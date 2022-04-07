-- copy from https://github.com/input-output-hk/ouroboros-network/blob/master/io-classes/src/Control/Monad/Class/MonadTimer.hs
{-# LANGUAGE NumericUnderscores #-}

module Process.Timer where

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import qualified Control.Concurrent.STM as STM
import Control.Exception (assert)
import Control.Monad (forever)
import Data.Time (DiffTime, diffTimeToPicoseconds)
import qualified GHC.Event as GHC
  ( TimeoutKey,
    getSystemTimerManager,
    registerTimeout,
    unregisterTimeout,
    updateTimeout,
  )

data TimeoutState
  = TimeoutPending
  | TimeoutFired
  | TimeoutCancelled
  deriving (Show)

data Timeout = TimeoutIO !(STM.TVar TimeoutState) !GHC.TimeoutKey

readTimeout :: Timeout -> STM.STM TimeoutState
readTimeout (TimeoutIO var _key) = STM.readTVar var

newTimeout :: DiffTime -> IO Timeout
newTimeout = \d -> do
  var <- STM.newTVarIO TimeoutPending
  mgr <- GHC.getSystemTimerManager
  key <-
    GHC.registerTimeout
      mgr
      (diffTimeToMicrosecondsAsInt d)
      (STM.atomically (timeoutAction var))
  return (TimeoutIO var key)
  where
    timeoutAction var = do
      x <- STM.readTVar var
      case x of
        TimeoutPending -> STM.writeTVar var TimeoutFired
        TimeoutFired -> error "MonadTimer(IO): invariant violation"
        TimeoutCancelled -> return ()

updateTimeout :: Timeout -> DiffTime -> IO ()
updateTimeout (TimeoutIO _var key) d = do
  mgr <- GHC.getSystemTimerManager
  GHC.updateTimeout mgr key (diffTimeToMicrosecondsAsInt d)

cancelTimeout :: Timeout -> IO ()
cancelTimeout (TimeoutIO var key) = do
  STM.atomically $ do
    x <- STM.readTVar var
    case x of
      TimeoutPending -> STM.writeTVar var TimeoutCancelled
      TimeoutFired -> return ()
      TimeoutCancelled -> return ()
  mgr <- GHC.getSystemTimerManager
  GHC.unregisterTimeout mgr key

diffTimeToMicrosecondsAsInt :: DiffTime -> Int
diffTimeToMicrosecondsAsInt d =
  let usec :: Integer
      usec = diffTimeToPicoseconds d `div` 1_000_000
   in -- Can only represent usec times that fit within an Int, which on 32bit
      -- systems means 2^31 usec, which is only ~35 minutes.
      assert (usec <= fromIntegral (maxBound :: Int)) $
        fromIntegral usec

microsecondsAsIntToDiffTime :: Int -> DiffTime
microsecondsAsIntToDiffTime = (/ 1_000_000) . fromIntegral

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
      let nl = filter ((/= i) . fst) tmvs
      undefined

  print res
