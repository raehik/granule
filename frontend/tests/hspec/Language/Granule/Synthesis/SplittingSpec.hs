module Language.Granule.Synthesis.SplittingSpec where

import Test.Hspec hiding (Spec)
import qualified Test.Hspec as Test

import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts

import Language.Granule.Context

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Pattern

import Language.Granule.Synthesis.Splitting

import Language.Granule.Utils

spec :: Test.Spec
spec = let ?globals = mempty in do
  describe "case splitting" $ do
    -- not : Bool → Bool
    -- not x = {! x !}
    it "Boolean not function" $ do
      res <- runSplitter (FunTy Nothing (TyCon boolId) (TyCon boolId)) boolDataCons boolTyCons []  [(xId, Linear (TyCon boolId))]
      res `shouldBe` ([xId], [[PConstr nullSpan () False falseId []], [PConstr nullSpan () False trueId []]])

    -- i : ∀ { a : Type } . a → a
    -- i x = {! x !}
    it "Polymorphic identity" $ do
      res <- runSplitter (FunTy Nothing (TyVar aId) (TyVar aId)) [] [] [] [(xId, Linear (TyVar aId))]
      res `shouldBe` ([xId], [[PVar nullSpan () False xId]])

    -- i : ∀ { a : Type } . a → a
    -- i x = {! !}
    it "Empty hole" $ do
      res <- runSplitter (FunTy Nothing (TyVar aId) (TyVar aId)) [] [] [] []
      res `shouldBe` ([], [[]])


boolId, xId, aId, trueId, falseId :: Id
boolId = mkId "Bool"
xId = mkId "x"
aId = mkId "a"
trueId = mkId "True"
falseId = mkId "False"

boolDataCons :: (?globals :: Globals) => Ctxt (Ctxt (TypeScheme, Substitution))
boolDataCons =
  [(boolId, [(falseId, (Forall nullSpan [] [] (TyCon boolId), [])), (trueId, (Forall nullSpan [] [] (TyCon boolId), []))])]

boolTyCons :: Ctxt (Kind, [Id], Bool)
boolTyCons = [(boolId, (KType, [falseId, trueId], False))]

runSplitter :: (?globals :: Globals)
  => Type
  -> Ctxt (Ctxt (TypeScheme, Substitution))
  -> Ctxt (Kind, [Id], Bool)
  -> Ctxt (Kind, Quantifier)
  -> Ctxt Assumption
  -> IO ([Id], [[Pattern ()]])
runSplitter ty dataCons tyCons tyVarCtxt ctxt = do
  let st = initState {
    patternConsumption = repeat NotFull,
    dataConstructors = concatMap snd dataCons,
    typeConstructors = tyCons,
    tyVarContext = tyVarCtxt,
    equationTy = Just ty }
  (Right (ids, res), _) <- runChecker st (generateCases nullSpan dataCons ctxt)
  return (ids, map fst res)