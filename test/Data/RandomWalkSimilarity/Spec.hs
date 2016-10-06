{-# LANGUAGE DataKinds #-}
module Data.RandomWalkSimilarity.Spec where

import Data.Functor.Both
import Data.RandomWalkSimilarity
import Data.Record
import qualified Data.Vector as Vector
import Diff
import Info
import Patch
import Prologue
import Syntax
import Term
import Term.Arbitrary
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

spec :: Spec
spec = parallel $ do
  let positively = succ . abs
  describe "pqGramDecorator" $ do
    prop "produces grams with stems of the specified length" $
      \ (term, p, q) -> pqGramDecorator (rhead . headF) (positively p) (positively q) (toTerm term :: Term (Syntax Text) (Record '[Text])) `shouldSatisfy` all ((== positively p) . length . stem . rhead)

    prop "produces grams with bases of the specified width" $
      \ (term, p, q) -> pqGramDecorator (rhead . headF) (positively p) (positively q) (toTerm term :: Term (Syntax Text) (Record '[Text])) `shouldSatisfy` all ((== positively q) . length . base . rhead)

  describe "featureVectorDecorator" $ do
    prop "produces a vector of the specified dimension" $
      \ (term, p, q, d) -> featureVectorDecorator (rhead . headF) (positively p) (positively q) (positively d) (toTerm term :: Term (Syntax Text) (Record '[Text])) `shouldSatisfy` all ((== positively d) . length . rhead)

  describe "rws" $ do
    let toTerm' = decorate . toTerm
    prop "produces correct diffs" . forAll (scale (`div` 4) arbitrary) $
      \ (as, bs) -> let tas = toTerm' <$> (as :: [ArbitraryTerm Text (Record '[Category])])
                        tbs = toTerm' <$> (bs :: [ArbitraryTerm Text (Record '[Category])])
                        root = cofree . ((Program .: RNil) :<) . Indexed
                        diff = wrap (pure (Program .: RNil) :< Indexed (stripDiff <$> rws compare tas tbs)) in
        (beforeTerm diff, afterTerm diff) `shouldBe` (Just (root (stripTerm <$> tas)), Just (root (stripTerm <$> tbs)))

    it "produces unbiased insertions within branches" $
      let (a, b) = (decorate (cofree ((StringLiteral .: RNil) :< Indexed [ cofree ((StringLiteral .: RNil) :< Leaf ("a" :: Text)) ])), decorate (cofree ((StringLiteral .: RNil) :< Indexed [ cofree ((StringLiteral .: RNil) :< Leaf "b") ]))) in
      fmap stripDiff (rws compare [ b ] [ a, b ]) `shouldBe` fmap stripDiff [ inserting a, copying b ]

  where compare :: (HasField fields Category, Functor f, Eq (Cofree f Category)) => Term f (Record fields) -> Term f (Record fields) -> Maybe (Diff f (Record fields))
        compare a b | (category <$> a) == (category <$> b) = Just (copying b)
                    | otherwise = if ((==) `on` category . extract) a b then Just (replacing a b) else Nothing
        copying :: Functor f => Cofree f (Record fields) -> Free (CofreeF f (Both (Record fields))) (Patch (Cofree f (Record fields)))
        copying = cata wrap . fmap pure
        decorate :: SyntaxTerm leaf '[Category] -> SyntaxTerm leaf '[Vector.Vector Double, Category]
        decorate = defaultFeatureVectorDecorator (category . headF)