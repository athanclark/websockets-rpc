{-# LANGUAGE
    OverloadedStrings
  , DeriveGeneric
  , DeriveDataTypeable
  , GeneralizedNewtypeDeriving
  , NamedFieldPuns
  #-}

module Network.WebSockets.RPC.Types where

import Data.Data (Data, Typeable)
import GHC.Generics (Generic)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=), object)
import Data.Aeson.Types (typeMismatch, Value (Object, String))
import qualified Data.HashMap.Lazy as HM
import Data.Text (Text)


-- | Unique identifier for an RPC session
newtype RPCID = RPCID {getRPCID :: Int}
  deriving (Eq, Ord, Enum, Bounded, Generic, Data, Typeable, FromJSON, ToJSON)


data RPCIdentified a = RPCIdentified
  { _ident  :: {-# UNPACK #-} !RPCID
  , _params :: !a
  } deriving (Eq, Generic, Data, Typeable)

instance ToJSON a => ToJSON (RPCIdentified a) where
  toJSON RPCIdentified {_ident,_params} = object
    [ "ident"  .= _ident
    , "params" .= _params
    ]

instance FromJSON a => FromJSON (RPCIdentified a) where
  parseJSON (Object o) = RPCIdentified <$> o .: "ident" <*> o .: "params"
  parseJSON x = typeMismatch "RPCIdentified" x


-- * RPC Methods

newtype Subscribe a = Subscribe {getSubscribe :: RPCIdentified a}
  deriving (Eq, Generic, Data, Typeable)

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

newtype Supply    a = Supply    {getSupply    :: RPCIdentified a}
  deriving (Eq, Generic, Data, Typeable)

instance ToJSON a => ToJSON (Supply a) where
  toJSON (Supply x) = case toJSON x of
    Object xs -> Object (HM.insert "type" (String "sup") xs)
    _         -> error "inconceivable!"

instance FromJSON a => FromJSON (Supply a) where
  parseJSON x@(Object o) = do
    t <- o .: "type"
    if t == ("sup" :: Text)
      then Supply <$> parseJSON x
      else fail "Not a supply"
  parseJSON x = typeMismatch "Supply" x

newtype Reply     a = Reply     {getReply     :: RPCIdentified a}
  deriving (Eq, Generic, Data, Typeable)

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

newtype Complete  a = Complete  {getComplete  :: RPCIdentified a}
  deriving (Eq, Generic, Data, Typeable)

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
