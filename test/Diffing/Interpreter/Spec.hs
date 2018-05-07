{-# LANGUAGE DataKinds #-}
module Diffing.Interpreter.Spec where

import Data.Diff
import Data.Functor.Listable
import Data.Record
import Data.Sum
import Data.Term
import Diffing.Interpreter
import qualified Data.Syntax as Syntax
import Test.Hspec (Spec, describe, it, parallel)
import Test.Hspec.Expectations.Pretty
import Test.Hspec.LeanCheck

spec :: Spec
spec = parallel $ do
  describe "diffTerms" $ do
    it "returns a replacement when comparing two unicode equivalent terms" $
      let termA = termIn Nil (injectSum (Syntax.Identifier "t\776"))
          termB = termIn Nil (injectSum (Syntax.Identifier "\7831")) in
          diffTerms termA termB `shouldBe` replacing termA (termB :: Term ListableSyntax (Record '[]))

    prop "produces correct diffs" $
      \ a b -> let diff = diffTerms a b :: Diff ListableSyntax (Record '[]) (Record '[]) in
                   (beforeTerm diff, afterTerm diff) `shouldBe` (Just a, Just b)

    prop "produces identity diffs for equal terms " $
      \ a -> let diff = diffTerms a a :: Diff ListableSyntax (Record '[]) (Record '[]) in
                 length (diffPatches diff) `shouldBe` 0

    it "produces unbiased insertions within branches" $
      let term s = termIn Nil (injectSum [ termIn Nil (injectSum (Syntax.Identifier s)) ]) :: Term ListableSyntax (Record '[])
          wrap = termIn Nil . injectSum in
      diffTerms (wrap [ term "b" ]) (wrap [ term "a", term "b" ]) `shouldBe` merge (Nil, Nil) (injectSum [ inserting (term "a"), merging (term "b") ])

    prop "compares nodes against context" $
      \ a b -> diffTerms a (termIn Nil (injectSum (Syntax.Context (pure b) a))) `shouldBe` insertF (In Nil (injectSum (Syntax.Context (pure (inserting b)) (merging (a :: Term ListableSyntax (Record '[]))))))

    prop "diffs forward permutations as changes" $
      \ a -> let wrap = termIn Nil . injectSum
                 b = wrap [a]
                 c = wrap [a, b] in
        diffTerms (wrap [a, b, c]) (wrap [c, a, b :: Term ListableSyntax (Record '[])]) `shouldBe` merge (Nil, Nil) (injectSum [ inserting c, merging a, merging b, deleting c ])

    prop "diffs backward permutations as changes" $
      \ a -> let wrap = termIn Nil . injectSum
                 b = wrap [a]
                 c = wrap [a, b] in
        diffTerms (wrap [a, b, c]) (wrap [b, c, a :: Term ListableSyntax (Record '[])]) `shouldBe` merge (Nil, Nil) (injectSum [ deleting a, merging b, merging c, inserting a ])
