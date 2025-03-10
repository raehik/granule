{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Helpers for working with type variables in the type checker
module Language.Granule.Checker.Variables where

import Control.Monad.Trans.Identity
import Control.Monad.State.Strict

import qualified Data.Map as M

import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Type

-- | Generate a fresh alphanumeric identifier name string
freshIdentifierBase :: String -> Checker String
freshIdentifierBase s = do
  checkerState <- get
  let vmap = uniqueVarIdCounterMap checkerState
  let s' = takeWhile (\c -> c /= '`') s
  case M.lookup s' vmap of
    Nothing -> do
      let vmap' = M.insert s' 1 vmap
      put checkerState { uniqueVarIdCounterMap = vmap' }
      return $ s' <> "." <> show 0

    Just n -> do
      let vmap' = M.insert s' (n+1) vmap
      put checkerState { uniqueVarIdCounterMap = vmap' }
      return $ s' <> "." <> show n

-- | Helper for creating a few (existential) coeffect variable of a particular
--   coeffect type.
freshTyVarInContext :: Id -> Type -> Checker Id
freshTyVarInContext cvar k = do
    freshTyVarInContextWithBinding cvar k InstanceQ

-- | Helper for creating a few (existential) coeffect variable of a particular
--   coeffect type.
freshTyVarInContextWithBinding :: Id -> Type -> Quantifier -> Checker Id
freshTyVarInContextWithBinding var k q = do
    freshName <- freshIdentifierBase (internalName var)
    let var' = mkId freshName
    registerTyVarInContext var' k q
    return var'

-- | Helper for registering a new coeffect variable in the checker
registerTyVarInContext :: Id -> Type -> Quantifier -> Checker ()
registerTyVarInContext v t q = do
    modify (\st -> st { tyVarContext = (v, (t, q)) : tyVarContext st })

-- | Helper for registering a new coeffect variable in the checker only
--   within the scope of a particular computation
registerTyVarInContextWith :: (MonadTrans m, Monad (m Checker))
    => Id -> Type -> Quantifier -> m Checker a -> m Checker a
registerTyVarInContextWith v t q cont = do
  -- save ty var context
  st <- lift $ get
  let tyvc = tyVarContext st
  -- register variable, type, and quantifier
  lift $ registerTyVarInContext v t q
  -- run continuation
  res <- cont
  -- reinstate original type variable context
  lift $ modify $ \st -> st { tyVarContext = tyvc }
  return res

registerTyVarInContextWith' ::
  Id -> Type -> Quantifier -> Checker a -> Checker a
registerTyVarInContextWith' v t q m =
  runIdentityT $ registerTyVarInContextWith v t q (IdentityT m)