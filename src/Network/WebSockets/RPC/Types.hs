{-# LANGUAGE
    OverloadedStrings
  , DeriveGeneric
  , DeriveDataTypeable
  , GeneralizedNewtypeDeriving
  , NamedFieldPuns
  #-}

module Network.WebSockets.RPC.Types
  ( RPCID, getRPCID
  , -- * RPC Methods
    RPCIdentified (..), Subscribe (Subscribe), Supply (..), Reply (Reply), Complete (Complete)
  , -- ** Categorized
    ClientToServer (..), ServerToClient (..)
  , -- * Exceptions
    WebSocketRPCException (..)
  ) where

import Data.Data (Data, Typeable)
import GHC.Generics (Generic)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=), object)
import Data.Aeson.Types (typeMismatch, Value (Object, String))
import qualified Data.HashMap.Lazy as HM
import Data.Text (Text)
import Data.ByteString.Lazy (ByteString)

import Control.Applicative ((<|>))
import Control.Monad.Catch (Exception)

import Test.QuickCheck (Arbitrary (..), CoArbitrary)


-- | Unique identifier for an RPC session
newtype RPCID = RPCID {getRPCID :: Int}
  deriving (Show, Read, Eq, Ord, Enum, Bounded, Generic, Data, Typeable, FromJSON, ToJSON, Arbitrary, CoArbitrary)


data RPCIdentified a = RPCIdentified
  { _ident  :: {-# UNPACK #-} !RPCID
  , _params :: !a
  } deriving (Show, Read, Eq, Generic, Data, Typeable)

instance ToJSON a => ToJSON (RPCIdentified a) where
  toJSON RPCIdentified {_ident,_params} = object
    [ "ident"  .= _ident
    , "params" .= _params
    ]

instance FromJSON a => FromJSON (RPCIdentified a) where
  parseJSON (Object o) = RPCIdentified <$> o .: "ident" <*> o .: "params"
  parseJSON x = typeMismatch "RPCIdentified" x

instance Arbitrary a => Arbitrary (RPCIdentified a) where
  arbitrary = RPCIdentified <$> arbitrary <*> arbitrary
  shrink RPCIdentified{_ident,_params} = RPCIdentified <$> shrink _ident <*> shrink _params



newtype Subscribe a = Subscribe {getSubscribe :: RPCIdentified a}
  deriving (Show, Read, Eq, Generic, Data, Typeable, Arbitrary)


instance ToJSON a => ToJSON (Subscribe a) where
  toJSON (Subscribe x) = case toJSON x of
    Object xs -> Object (HM.insert "type" (String "sub") xs)
    _         -> error "inconceivable!"

instance FromJSON a => FromJSON (Subscribe a) where
  parseJSON x@(Object o) = do
    t <- o .: "type"
    if t == ("sub" :: Text)
      then Subscribe <$> parseJSON x
      else fail "Not a subscription"
  parseJSON x = typeMismatch "Subscribe" x


-- | @Nothing@ means the RPC is canceled
newtype Supply a = Supply { getSupply :: RPCIdentified (Maybe a) }
  deriving (Show, Read, Eq, Generic, Data, Typeable, Arbitrary)

instance ToJSON a => ToJSON (Supply a) where
  toJSON Supply {getSupply} = case toJSON getSupply of
    Object xs -> Object (HM.insert "type" (String "sup") xs)
    _         -> error "inconceivable!"

instance FromJSON a => FromJSON (Supply a) where
  parseJSON x@(Object o) = do
    t <- o .: "type"
    if t == ("sup" :: Text)
      then Supply <$> parseJSON x
      else fail "Not a supply"
  parseJSON x = typeMismatch "Supply" x


newtype Reply a = Reply {getReply :: RPCIdentified a}
  deriving (Show, Read, Eq, Generic, Data, Typeable, Arbitrary)

instance ToJSON a => ToJSON (Reply a) where
  toJSON (Reply x) = case toJSON x of
    Object xs -> Object (HM.insert "type" (String "rep") xs)
    _         -> error "inconceivable!"

instance FromJSON a => FromJSON (Reply a) where
  parseJSON x@(Object o) = do
    t <- o .: "type"
    if t == ("rep" :: Text)
      then Reply <$> parseJSON x
      else fail "Not a reply"
  parseJSON x = typeMismatch "Reply" x


newtype Complete a = Complete {getComplete :: RPCIdentified a}
  deriving (Show, Read, Eq, Generic, Data, Typeable, Arbitrary)

instance ToJSON a => ToJSON (Complete a) where
  toJSON (Complete x) = case toJSON x of
    Object xs -> Object (HM.insert "type" (String "com") xs)
    _         -> error "inconceivable!"

instance FromJSON a => FromJSON (Complete a) where
  parseJSON x@(Object o) = do
    t <- o .: "type"
    if t == ("com" :: Text)
      then Complete <$> parseJSON x
      else fail "Not a complete"
  parseJSON x = typeMismatch "Complete" x


data ClientToServer sub sup
  = Sub (Subscribe sub)
  | Sup (Supply sup)
  deriving (Show, Read, Eq, Generic, Data, Typeable)

instance (Arbitrary sub, Arbitrary sup) => Arbitrary (ClientToServer sub sup) where
  arbitrary = do
    q <- arbitrary
    if q then Sub <$> arbitrary else Sup <$> arbitrary

instance (ToJSON sub, ToJSON sup) => ToJSON (ClientToServer sub sup) where
  toJSON (Sub x) = toJSON x
  toJSON (Sup x) = toJSON x

instance (FromJSON sub, FromJSON sup) => FromJSON (ClientToServer sub sup) where
  parseJSON x = (Sub <$> parseJSON x) <|> (Sup <$> parseJSON x)

data ServerToClient rep com
  = Rep (Reply rep)
  | Com (Complete com)
  deriving (Show, Read, Eq, Generic, Data, Typeable)

instance (Arbitrary sub, Arbitrary sup) => Arbitrary (ServerToClient sub sup) where
  arbitrary = do
    q <- arbitrary
    if q then Rep <$> arbitrary else Com <$> arbitrary

instance (ToJSON rep, ToJSON com) => ToJSON (ServerToClient rep com) where
  toJSON (Rep x) = toJSON x
  toJSON (Com x) = toJSON x

instance (FromJSON rep, FromJSON com) => FromJSON (ServerToClient rep com) where
  parseJSON x = (Rep <$> parseJSON x) <|> (Com <$> parseJSON x)


data WebSocketRPCException
  = WebSocketRPCParseFailure [String] ByteString
  deriving (Show, Generic)

instance Exception WebSocketRPCException
