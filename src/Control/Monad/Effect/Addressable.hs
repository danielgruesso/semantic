{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, UndecidableInstances #-}
module Control.Monad.Effect.Addressable where

import Control.Applicative
import Control.Monad ((<=<))
import Control.Monad.Effect (Eff)
import Control.Monad.Effect.Fail
import Control.Monad.Effect.State
import Data.Abstract.Address
import Data.Abstract.Environment
import Data.Abstract.FreeVariables
import Data.Abstract.Store
import Data.Abstract.Value
import Data.Foldable (asum, toList)
import Data.Pointed
import Data.Semigroup
import Data.Union
import Prelude hiding (fail)

-- | Defines 'alloc'ation and 'deref'erencing of 'Address'es in a Store.
class (Ord l, Pointed (Cell l)) => Addressable l es where
  deref :: (Member (State (StoreFor a)) es , Member Fail es , l ~ LocationFor a)
        => Address l a -> Eff es a

  alloc :: (Member (State (StoreFor a)) es, l ~ LocationFor a)
        => Name -> Eff es (Address l a)

-- | Look up or allocate an address for a 'Name' free in a given term & assign it a given value, returning the 'Name' paired with the address.
--
--   The term is expected to contain one and only one free 'Name', meaning that care should be taken to apply this only to e.g. identifiers.
lookupOrAlloc ::
                 ( FreeVariables t
                 , Semigroup (Cell (LocationFor a) a)
                 , Member (State (StoreFor a)) es
                 , Addressable (LocationFor a) es
                 )
                 => t
                 -> a
                 -> Environment (LocationFor a) a
                 -> Eff es (Name, Address (LocationFor a) a)
lookupOrAlloc term = let [name] = toList (freeVariables term) in
                         lookupOrAlloc' name
  where
    -- | Look up or allocate an address for a 'Name' & assign it a given value, returning the 'Name' paired with the address.
    lookupOrAlloc' ::
                      ( Semigroup (Cell (LocationFor a) a)
                      , Member (State (StoreFor a)) es
                      , Addressable (LocationFor a) es
                      )
                      => Name
                      -> a
                      -> Environment (LocationFor a) a
                      -> Eff es (Name, Address (LocationFor a) a)
    lookupOrAlloc' name v env = do
      a <- maybe (alloc name) pure (envLookup name env)
      assign a v
      pure (name, a)

-- | Write a value to the given 'Address' in the 'Store'.
assign ::
       ( Ord (LocationFor a)
       , Semigroup (Cell (LocationFor a) a)
       , Pointed (Cell (LocationFor a))
       , Member (State (StoreFor a)) es
       )
       => Address (LocationFor a) a
       -> a
       -> Eff es ()
assign address = modify . storeInsert address


-- Instances

-- | 'Precise' locations are always 'alloc'ated a fresh 'Address', and 'deref'erence to the 'Latest' value written.
instance Addressable Precise es where
  deref = maybe uninitializedAddress (pure . unLatest) <=< flip fmap get . storeLookup
    where
      -- | Fail with a message denoting an uninitialized address (i.e. one which was 'alloc'ated, but never 'assign'ed a value before being 'deref'erenced).
      uninitializedAddress :: Member Fail es => Eff es a
      uninitializedAddress = fail "uninitialized address"

  alloc _ = fmap allocPrecise get
    where allocPrecise :: Store Precise a -> Address Precise a
          allocPrecise = Address . Precise . storeSize


-- | 'Monovariant' locations 'alloc'ate one 'Address' per unique variable name, and 'deref'erence once per stored value, nondeterministically.
instance (Alternative (Eff es)) => Addressable Monovariant es where
  deref = asum . maybe [] (map pure . toList) <=< flip fmap get . storeLookup

  alloc = pure . Address . Monovariant