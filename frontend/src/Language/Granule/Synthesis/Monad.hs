{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}

module Language.Granule.Synthesis.Monad where

import Language.Granule.Context
import Language.Granule.Checker.Monad

import Data.List.NonEmpty (NonEmpty(..))
import Control.Monad.Except
import Control.Monad.State.Strict
import Control.Monad.Logic
import qualified System.Clock as Clock
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts (Substitution)
import Language.Granule.Syntax.Type (TypeScheme)
import Language.Granule.Syntax.Identifiers
import Language.Granule.Utils

-- Data structure for collecting information about synthesis
data SynthesisData =
  SynthesisData {
    smtCallsCount             :: Integer
  , smtTime                   :: Double
  , proveTime                 :: Double -- longer than smtTime as it includes compilation of predicates to SMT
  , theoremSizeTotal          :: Integer
  , paths                     :: Integer
  , startTime                 :: Clock.TimeSpec
  , constructors              :: Ctxt (Ctxt (TypeScheme, Substitution), Bool)
  , currDef                   :: [Id]
  , maxReached                :: Bool
  }
  deriving Show

instance Semigroup SynthesisData where
 (SynthesisData c smt t s p st cons def max) <>
    (SynthesisData c' smt' t' s' p' st' cons' def' max') =
      SynthesisData
        (c + c')
        (smt + smt')
        (t + t')
        (s + s')
        (p + p')
        (st + st')
        (cons ++ cons')
        (def ++ def')
        (max || max')

instance Monoid SynthesisData where
  mempty  = SynthesisData 0 0 0 0 0 0 [] [] False
  mappend = (<>)

-- Synthesiser monad

newtype Synthesiser a = Synthesiser
  { unSynthesiser ::
    (ExceptT (NonEmpty CheckerError) (StateT CheckerState (LogicT (StateT SynthesisData IO)))) a }
  deriving (Functor, Applicative, MonadState CheckerState, MonadError (NonEmpty CheckerError))


-- Synthesiser always uses fair bind from LogicT
instance Monad Synthesiser where
  return = pure
  k >>= f =
    Synthesiser $ ExceptT (StateT
       (\s -> unSynth k s >>- (\(eb, s) ->
          case eb of
            Left r -> do
              -- Useful for debugging tests
              -- liftIO $ putStrLn $ "checker error: " ++ (show r)
              mzero
            Right b -> (unSynth . f) b s)))

     where
       unSynth m = runStateT (runExceptT (unSynthesiser m))

-- Monad transformer definitions

instance MonadIO Synthesiser where
  liftIO = conv . liftIO

runSynthesiser ::  Int -> Synthesiser a
  -> (CheckerState -> StateT SynthesisData IO [((Either (NonEmpty CheckerError) a), CheckerState)])
runSynthesiser index m s = do
  observeManyT index (runStateT (runExceptT (unSynthesiser m)) s)

conv :: Checker a -> Synthesiser a
conv (Checker k) =
  Synthesiser
    (ExceptT
         (StateT (\s -> lift $ lift $  (runStateT (runExceptT k) (s)))))

try :: Synthesiser a -> Synthesiser a -> Synthesiser a
try m n = do
  Synthesiser $ lift $ lift $ lift $ modify (\state ->
    state {
      paths = 1 + paths state
      })
  Synthesiser $ ExceptT ((runExceptT (unSynthesiser m)) `interleave` (runExceptT (unSynthesiser n)))


none :: (?globals :: Globals) => Synthesiser a
none = do
  when interactiveDebugging $ do
    liftIO $ putStrLn "<<< none HERE. Press any key to continue"
    _ <- liftIO $ getLine
    return ()
  Synthesiser (ExceptT mzero)

maybeToSynthesiser :: (?globals :: Globals) => Maybe (Ctxt a) -> Synthesiser (Ctxt a)
maybeToSynthesiser (Just x) = return x
maybeToSynthesiser Nothing = none

boolToSynthesiser :: (?globals :: Globals) => Bool -> a -> Synthesiser a
boolToSynthesiser True x = return x
boolToSynthesiser False _ = none



getSynthState ::  Synthesiser (SynthesisData)
getSynthState = Synthesiser $ lift $ lift $ get

modifyPred :: (PredContext -> PredContext) -> Synthesiser ()
modifyPred f = Synthesiser $ lift $ modify (\s -> s { predicateContext = f $ predicateContext s })

data Measurement =
  Measurement {
    smtCalls        :: Integer
  , synthTime       :: Double
  , proverTime      :: Double
  , solverTime      :: Double
  , meanTheoremSize :: Double
  , success         :: Bool
  , timeout         :: Bool
  , pathsExplored   :: Integer

  } deriving Show

instance Semigroup Measurement where
 (Measurement smt synTime provTime solveTime meanTheorem success timeout paths) <>
  (Measurement smt' synTime' provTime' solveTime' meanTheorem' success' timeout' paths') =
    Measurement
      (smt + smt')
      (synTime + synTime')
      (provTime + provTime')
      (solveTime + solveTime')
      (meanTheorem + meanTheorem')
      (success || success')
      (timeout || timeout')
      (paths + paths')

instance Monoid Measurement where
  mempty  = Measurement 0 0.0 0.0 0.0 0.0 False False 0
  mappend = (<>)