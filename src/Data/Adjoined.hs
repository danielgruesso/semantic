module Data.Adjoined where

import Control.Monad
import Data.Sequence as Seq

newtype Adjoined a = Adjoined { unAdjoined :: Seq a }
  deriving (Eq, Foldable, Functor, Show, Traversable)

instance Applicative Adjoined where
  pure = return
  (<*>) = ap

instance Monad Adjoined where
  return = Adjoined . return
  Adjoined a >>= f = case viewl a of
    EmptyL -> Adjoined empty
    (a :< as) -> Adjoined $ unAdjoined (f a) >< unAdjoined (Adjoined as >>= f)

type Coalesce a = a -> a -> [a]

mappendBy :: Coalesce a -> Adjoined a -> Adjoined a -> Adjoined a
mappendBy coalesce (Adjoined a) (Adjoined b) = case (viewr a, viewl b) of
  (as :> a', b' :< bs) -> Adjoined $ as >< Seq.fromList (coalesce a' b') >< bs
  _ -> Adjoined (a >< b)
