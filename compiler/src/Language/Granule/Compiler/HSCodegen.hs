-- | Generate Haskell code from Granule

{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_GHC -Wno-typed-holes #-}
{-# LANGUAGE NamedFieldPuns #-}
module Language.Granule.Compiler.HSCodegen where

import Control.Monad
import Data.Functor
import Control.Monad.State
import Control.Monad.Except

import Language.Granule.Compiler.Util as Hs
import Language.Granule.Compiler.Error

import Language.Granule.Syntax.Def as GrDef
import Language.Granule.Syntax.Pattern as GrPat
import Language.Granule.Syntax.Annotated
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Expr as GrExpr
import Language.Granule.Syntax.Type as GrType
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.FirstParameter
import Data.Text (unpack)

import Debug.Trace

type CExpr = GrExpr.Expr  () ()
type CVal  = GrExpr.Value () ()
type CPat  = GrPat.Pattern   ()
type CAst  = AST          () ()

type Compiler m = MonadError CompilerError m

cg :: CAst -> Either CompilerError String
cg ast = join (runExceptT (do mod <- cgModule ast
                              return $ prettyPrint mod))

cgModule :: Compiler m => CAst -> m (Module ())
cgModule ast = do
  decls <- cgDefs ast
  return $ Module () Nothing [grPragmas] [grImport] decls

cgDefs :: Compiler m => CAst -> m [Decl ()]
cgDefs (AST dd defs imports _ _) =
  do defs' <- mapM cgDef  defs <&> concat
     dd'   <- mapM cgData dd   <&> concat
     return $ dd' ++ defs'

cgDef :: Compiler m => Def () () -> m [Decl ()]
cgDef (Def _ id _ EquationList{equations} typeschemes) = do
  scheme <- cgTypeScheme typeschemes
  let bodies = map equationBody     equations
      pats   = map equationPatterns equations
  pats'   <- mapM cgPats  pats
  bodies' <- mapM cgExpr bodies
  let cases = zip pats' bodies'
      impl = mkEquation (mkName id) cases
      sig  = TypeSig () [mkName id] scheme
  return [sig,impl]

cgData :: Compiler m => DataDecl -> m [Decl ()]
cgData (GrDef.DataDecl _ id tyvars _ constrs) = do
  conDecls <- mapM (cgDataConstr id tyvars) constrs
  let dhead = foldr ((\i a -> DHApp () a $ UnkindedVar () i) . (mkName . fst))
                    (DHead () (mkName id)) tyvars
  return [Hs.GDataDecl () (DataType ()) Nothing dhead Nothing conDecls []]

cgDataConstr :: Compiler m => Id -> [(Id,GrType.Kind)] -> DataConstr -> m (GadtDecl ())
cgDataConstr _ ls (DataConstrIndexed _ i scheme) = do
  scheme' <- cgTypeScheme scheme
  return $ GadtDecl () (mkName i) Nothing Nothing Nothing scheme'
cgDataConstr id ls d@(DataConstrNonIndexed s i tys) =
  cgDataConstr id ls $ nonIndexedToIndexed id i ls d

nonIndexedToIndexed :: Id -> Id -> [(Id, GrType.Kind)] -> DataConstr -> DataConstr
nonIndexedToIndexed _  _     _      d@DataConstrIndexed{} = d
nonIndexedToIndexed id tName tyVars (DataConstrNonIndexed sp dName params)
    = DataConstrIndexed sp dName (Forall sp [] [] ty)
  where
    ty = foldr (FunTy Nothing Nothing) (returnTy (GrType.TyCon id) tyVars) params
    returnTy t [] = t
    returnTy t (v:vs) = returnTy (GrType.TyApp t ((GrType.TyVar . fst) v)) vs

cgTypeScheme :: Compiler m => TypeScheme -> m (Hs.Type ())
cgTypeScheme (Forall _ binders constraints typ) = do
  typ' <- cgType typ
  let tyVars = map (UnkindedVar () . mkName . fst) binders
  return $ TyForall () (Just tyVars) Nothing typ'

cgPats :: Compiler m => [CPat] -> m [Pat ()]
cgPats = mapM cgPat

cgPat :: Compiler m => CPat -> m (Pat ())
cgPat (GrPat.PVar _ _ _ i) =
  return $ Hs.PVar () $ mkName i
cgPat GrPat.PWild{} =
  return $ PWildCard ()
cgPat (GrPat.PBox _ _ _ pt) =
  cgPat pt
cgPat (GrPat.PInt _ _ _ n) =
  return $ PLit () (Signless ()) $ Int () (fromIntegral n) (show n)
cgPat (GrPat.PFloat _ _ _ n) =
  return $ PLit () (Signless ()) $ Frac () (toRational n) (show n)
cgPat (GrPat.PConstr _ _ _ i l_pt)
  | i == Id "," ","  = do
      pts <- mapM cgPat l_pt
      return $ pTuple pts
  | otherwise = do
      pts <- mapM cgPat l_pt
      return $ PApp () (UnQual () $ mkName i) pts

cgType :: Compiler m => GrType.Type -> m (Hs.Type ())
cgType (GrType.Type i) = return $ TyStar ()
cgType (GrType.FunTy _ _ t1 t2) = do
  t1' <- cgType t1
  t2' <- cgType t2
  return $ Hs.TyFun () t1' t2'
cgType (GrType.TyCon i) =
  return $ Hs.TyCon () $ UnQual () $ mkName i
cgType (GrType.Box t t2) = cgType t2
cgType (GrType.Diamond t t2) = do
  t2' <- cgType t2
  return $ Hs.TyApp () (Hs.TyCon () $ UnQual () $ name "IO") t2'
cgType (GrType.TyVar i) =
  return $ Hs.TyVar () $ mkName i
cgType (GrType.TyApp t1 t2) =
  if isTupleType t1
  then cgTypeTuple t1 t2
  else do
    t1' <- cgType t1
    t2' <- cgType t2
    return $ Hs.TyApp () t1' t2'
cgType (GrType.Star _t t2) = cgType t2
cgType (GrType.TyInt i) = return mkUnit
cgType (GrType.TyRational ri) = return mkUnit
cgType (GrType.TyGrade mt i) = return mkUnit
cgType (GrType.TyInfix t1 t2 t3) = return mkUnit
cgType (GrType.TySet p l_t) = return mkUnit
cgType (GrType.TyCase t l_p_tt) = unsupported "cgType: tycase not implemented"
cgType (GrType.TySig t t2) = unsupported "cgType: tysig not implemented"
cgType (GrType.TyExists _ _ _) = unsupported "cgType: tyexists not implemented"

isTupleType :: GrType.Type -> Bool
isTupleType (GrType.TyApp (GrType.TyCon id) _) = id == Id "," ","
isTupleType _oth = False

cgTypeTuple :: Compiler m => GrType.Type -> GrType.Type -> m (Hs.Type ())
cgTypeTuple (GrType.TyApp (GrType.TyCon _id) t1) t2 = do
  t1' <- cgType t1
  t2' <- cgType t2
  return $ TyTuple () Boxed [t1', t2']
cgTypeTuple _ _ = error "expected tuple"

cgExpr :: Compiler m => CExpr -> m (Exp ())
cgExpr (GrExpr.App _ _ _ e1 e2) =
  if isTupleExpr e1
  then cgExprTuple e1 e2
  else do
  e1' <- cgExpr e1
  e2' <- cgExpr e2
  return $ app e1' e2'
cgExpr (GrExpr.AppTy _ _ _ e t) = unsupported "cgExpr: appty not implemented"
cgExpr (GrExpr.Binop _ _ _ op e1 e2) = do
  e1' <- cgExpr e1
  e2' <- cgExpr e2
  cgBinop op e1' e2'
cgExpr (GrExpr.LetDiamond _ _ _ p _ e1 e2) = do
  p' <- cgPat p
  e1' <- cgExpr e1
  e2' <- cgExpr e2
  let lam = lamE [p'] e2'
  return $ infixApp e1' (op $ sym ">>=") lam
cgExpr (GrExpr.TryCatch _ _ _ e1 p _ e2 e3) = unsupported "cgExpr: trycatch not implemented"
cgExpr (GrExpr.Val _ _ _ e) = cgVal e
cgExpr (GrExpr.Case _ _ _ ge cases) = do
  ge' <- cgExpr ge
  cases' <- forM cases $ \(p,e) -> do
    p' <- cgPat p
    e' <- cgExpr e
    return $ alt p' e'
  return $ caseE ge' cases'
cgExpr GrExpr.Unpack{} = error "cgExpr: existentials not implement"
cgExpr GrExpr.Hole{} = error "cgExpr: hole not implemented"

isTupleExpr :: CExpr -> Bool
isTupleExpr (GrExpr.App _ _ _ (GrExpr.Val _ _ _ (GrExpr.Constr _ i _)) _) = i == Id "," ","
isTupleExpr _ = False

cgExprTuple :: Compiler m => CExpr -> CExpr -> m (Exp ())
cgExprTuple (GrExpr.App _ _ _ (GrExpr.Val _ _ _ (GrExpr.Constr _ i _)) e1) e2 = do
  e1' <- cgExpr e1
  e2' <- cgExpr e2
  return $ tuple [e1', e2']
cgExprTuple _ _ = error "expected tuple"

cgVal :: Compiler m => CVal -> m (Exp ())
cgVal (Promote _ty ex) = cgExpr ex
cgVal (Pure ty ex) = error "cgVal: not implemented"
cgVal (GrExpr.Var _ty i)  =
  return $ Hs.Var () $ UnQual () $ mkName i
cgVal (NumInt n) =
  return $ Hs.Lit () $ Int () (fromIntegral n) (show n)
cgVal (NumFloat n) =
  return $ Hs.Lit () $ Frac () (toRational n) (show n)
cgVal (CharLiteral ch) =
  return $ Hs.Lit () $ Char () ch (show ch)
cgVal (StringLiteral str) =
  return $ app (Hs.Var () $ UnQual () $ name "pack")
               (Hs.Lit () $ Hs.String () (unpack str) (unpack str))
cgVal (Constr _ i vals) = do
  vals' <- mapM cgVal vals
  let con = Con () (UnQual () $ mkName i)
  return $ appFun con vals'
cgVal (Abs _ p _ ex) = do
  p' <- cgPat p
  ex' <- cgExpr ex
  return $ lamE [p'] ex'
cgVal Pack{} = error "Existentials unsupported in code gen"
cgVal Ext{} = unexpected "cgVal: unexpected Ext"


cgBinop :: Compiler m => Operator -> Exp () -> Exp () -> m (Exp ())
cgBinop OpLesser e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "<"))) e2
cgBinop OpLesserEq e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "<="))) e2
cgBinop OpGreater e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym ">"))) e2
cgBinop OpGreaterEq e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym ">="))) e2
cgBinop OpEq e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "=="))) e2
cgBinop OpNotEq e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "/="))) e2
cgBinop OpPlus e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "+"))) e2
cgBinop OpTimes e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "*"))) e2
cgBinop OpDiv e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "/"))) e2
cgBinop OpMinus e1 e2 =
  return $ InfixApp () e1 (QVarOp () (UnQual () (sym "-"))) e2
