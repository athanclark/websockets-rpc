{-# LANGUAGE
    NamedFieldPuns
  , DeriveGeneric
  , DeriveDataTypeable
  , DeriveFunctor
  , GeneralizedNewtypeDeriving
  , FlexibleInstances
  , MultiParamTypeClasses
  , UndecidableInstances
  , TypeFamilies
  #-}

module Network.WebSockets.RPC.Trans.Server
  ( WebSocketServerRPCT
  , runWebSocketServerRPCT'
  , getServerEnv
  , execWebSocketServerRPCT
  , -- * Utilities
    registerSubscribeSupply
  , unregisterSubscribeSupply
  , runSubscribeSupply
  , Env
  , newEnv
  ) where

import GHC.Generics (Generic)
import Data.Data (Typeable)

import Network.WebSockets.RPC.Types (RPCID, getRPCID)

import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO, writeTVar, TVar)
import Control.Concurrent.STM (atomically)

import Control.Monad.State.Class (MonadState)
import Control.Monad.Writer.Class (MonadWriter)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans (MonadTrans (lift))
import Control.Monad.Reader.Class (MonadReader (ask, local))
import Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask)

import Control.Monad.Reader (ReaderT (..))

import Data.IntMap.Lazy (IntMap)
import qualified Data.IntMap.Lazy as IntMap


newtype Cont sub sup m = Cont
  { getCont :: Either sub sup -> m ()
  }

data Env sub sup m = Env
  { rpcContsVar :: TVar (IntMap (Cont sub sup m))
  }

newEnv :: IO (Env sub sup m)
newEnv = Env <$> newTVarIO mempty


newtype WebSocketServerRPCT sub sup m a = WebSocketServerRPCT
  { runWebSocketServerRPCT :: ReaderT (Env sub sup m) m a
  } deriving ( Generic, Typeable, Functor, Applicative, Monad
             , MonadState s, MonadWriter w, MonadIO, MonadThrow, MonadCatch, MonadMask
             )

runWebSocketServerRPCT' :: Env sub sup m -> WebSocketServerRPCT sub sup m a -> m a
runWebSocketServerRPCT' env (WebSocketServerRPCT (ReaderT f)) = f env

getServerEnv :: Applicative m => WebSocketServerRPCT sub sup m (Env sub sup m)
getServerEnv = WebSocketServerRPCT (ReaderT (\env -> pure env))

execWebSocketServerRPCT :: MonadIO m => WebSocketServerRPCT sub sup m a -> m a
execWebSocketServerRPCT f = do
  env <- liftIO newEnv
  runWebSocketServerRPCT' env f

instance MonadTrans (WebSocketServerRPCT sub sup) where
  lift x = WebSocketServerRPCT (ReaderT (const x))

instance MonadReader r m => MonadReader r (WebSocketServerRPCT sub sup m) where
  ask                                       = WebSocketServerRPCT (ReaderT (const ask))
  local f (WebSocketServerRPCT (ReaderT g)) = WebSocketServerRPCT (ReaderT (\env -> local f (g env)))


registerSubscribeSupply :: MonadIO m => RPCID -> (Either sub sup -> m ()) -> WebSocketServerRPCT sub sup m ()
registerSubscribeSupply rpcId getCont =
  let f Env{rpcContsVar} = liftIO $ do
        conts <- readTVarIO rpcContsVar
        atomically (writeTVar rpcContsVar (IntMap.insert (getRPCID rpcId) Cont{getCont} conts))
  in  WebSocketServerRPCT (ReaderT f)

unregisterSubscribeSupply :: MonadIO m => RPCID -> WebSocketServerRPCT sub sup m ()
unregisterSubscribeSupply rpcId =
  let f Env{rpcContsVar} = liftIO $ do
        conts <- readTVarIO rpcContsVar
        atomically (writeTVar rpcContsVar (IntMap.delete (getRPCID rpcId) conts))
  in  WebSocketServerRPCT (ReaderT f)


runSubscribeSupply :: MonadIO m => RPCID -> Either sub sup -> WebSocketServerRPCT sub sup m ()
runSubscribeSupply rpcId x =
  let f Env{rpcContsVar} = do
        conts <- liftIO (readTVarIO rpcContsVar)
        case IntMap.lookup (getRPCID rpcId) conts of
          Nothing            -> pure () -- TODO throw notfound warning?
          Just Cont{getCont} -> getCont x
  in  WebSocketServerRPCT (ReaderT f)
