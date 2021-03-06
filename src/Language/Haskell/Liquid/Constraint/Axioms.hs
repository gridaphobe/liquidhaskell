{-# LANGUAGE DeriveFoldable            #-}
{-# LANGUAGE DeriveTraversable         #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Language.Haskell.Liquid.Constraint.Axioms (

    expandProofs

    -- * Combining proofs
  , makeCombineType
  , makeCombineVar

  ) where


import Literal

import Coercion
import DataCon
import CoreSyn
import Type
import TyCon
import TypeRep
import Var
import Name
import NameSet

import Text.PrettyPrint.HughesPJ hiding (first, sep)
import Control.Monad.State
import qualified Data.List           as L
import qualified Data.HashMap.Strict as M
import Data.Maybe               (fromJust)
import Language.Fixpoint.Types.Names
import Language.Fixpoint.Utils.Files

import qualified Language.Fixpoint.Types            as F

import Language.Haskell.Liquid.Types.Visitors (freeVars)
import Language.Haskell.Liquid.Types            hiding (binds, Loc, loc, freeTyVars, Def, HAxiom)
import qualified Language.Haskell.Liquid.Types as T
import Language.Haskell.Liquid.WiredIn
import Language.Haskell.Liquid.Types.RefType
import Language.Haskell.Liquid.Types.Visitors         hiding (freeVars)
import Language.Haskell.Liquid.GHC.Misc
import Language.Haskell.Liquid.GHC.SpanStack                 (showSpan)
import Language.Fixpoint.Misc
import Language.Haskell.Liquid.Constraint.ProofToCore
import Language.Haskell.Liquid.Transforms.CoreToLogic
import Language.Haskell.Liquid.Constraint.Types

import System.IO.Unsafe

import Prover.Types (Axiom(..), Query(..))
import qualified Prover.Types as P
import Prover.Solve (solve)
import Prover.Defunctionalize

import Debug.Trace (trace)
import qualified Data.HashSet        as S



class Provable a where

  expandProofs :: GhcInfo -> [(F.Symbol, SpecType)] -> a -> CG a
  expandProofs info sigs x =
    do (x, s) <- runState (expProofs x) <$> initAEEnv info sigs
       modify $ \st -> st {freshIndex = ae_index s}
       return x

  expProofs :: a -> Pr a
  expProofs = return


instance Provable CoreBind where
  -- expProofs (NonRec x e) | returnsProof x =  (\e -> Rec [(traceShow ("\n\nMake it Rec\n\n" ++ show (F.symbol x)) x,e)]) <$> (addRec (x,e) >> expProofs e)
  expProofs (NonRec x e) =
     do e' <- addRec (x,e) >> expProofs e
        if x `elem` freeVars S.empty e'
          then return $ Rec [(x, e')]
          else return $ NonRec x e'
  expProofs (Rec xes)    = Rec      <$> (addRecs xes  >> mapSndM expProofs xes)


instance Provable CoreExpr where
  expProofs ee@(App (App (Tick _ (Var f)) i) e) | isAuto f = grapInt i >>= expandAutoProof ee e
  expProofs ee@(App (App (Var f) i) e)          | isAuto f = grapInt i >>= expandAutoProof ee e
  expProofs ee@(App (Tick _ (App (Tick _ (Var f)) i)) e) | isAuto f = grapInt i >>= expandAutoProof ee e
  expProofs ee@(App (Tick _ (App (Var f) i)) e)          | isAuto f = grapInt i >>= expandAutoProof ee e


  expProofs ee@(App (App (Tick _ (Var f)) i) e) | isCases f = grapInt i >>= expandCasesProof ee e
  expProofs ee@(App (App (Var f) i) e)          | isCases f = grapInt i >>= expandCasesProof ee e
  expProofs ee@(App (Tick _ (App (Tick _ (Var f)) i)) e) | isCases f = grapInt i >>= expandCasesProof ee e
  expProofs ee@(App (Tick _ (App (Var f) i)) e)          | isCases f = grapInt i >>= expandCasesProof ee e

  expProofs (App e1 e2) = liftM2 App (expProofs e1) (expProofs e2)
  expProofs (Lam x e)   = addVar x >> liftM  (Lam x) (expProofs e)
  expProofs (Let b e)   = do b' <- expProofs b
                             addBind b'
                             liftM (Let b') (expProofs e)
  expProofs (Case e v t alts) = liftM2 (\e -> Case e v t) (expProofs e) (mapM (expProofsCase e) alts)
  expProofs (Cast e c)   = liftM (`Cast` c) (expProofs e)
  expProofs (Tick t e)   = liftM (Tick t) (expProofs e)

  expProofs (Var v)      = return $ Var v
  expProofs (Lit l)      = return $ Lit l
  expProofs (Type t)     = return $ Type t
  expProofs (Coercion c) = return $ Coercion c



expProofsCase :: CoreExpr -> CoreAlt -> Pr CoreAlt
expProofsCase (Var x) (DataAlt c, xs, e)
  = do addVars xs
       t <- L.lookup (symbol c) . ae_sigs <$> get
       addAssert $ makeRefinement t (x:xs)
       res <- liftM (DataAlt c,xs,) (expProofs e)
       rmAssert
       return res

expProofsCase _ (c, xs, e)
  = addVars xs >> liftM (c,xs,) (expProofs e)


instance Provable CoreAlt where
  expProofs (c, xs, e) = addVars xs >> liftM (c,xs,) (expProofs e)

expandCasesProof :: CoreExpr -> CoreExpr -> Integer -> Pr CoreExpr
expandCasesProof inite e it
  = do vs <-  reverse . ae_vars <$> get
       case L.find (isAlgType . varType) vs of
          Nothing -> return inite
          Just v  -> makeCases v inite e it

makeDataCons v = data_cons $ algTyConRhs tc
  where
    t  = varType v
    tc = fst $ splitTyConApp t

makeCases v inite e it = Case (Var v) v (varType v) <$> (mapM go $ makeDataCons v)
  where
    go c = do xs <- makeDataConArgs v c
              addVars xs
              t <- L.lookup (symbol c) . ae_sigs <$> get
              addAssert $ makeRefinement t (v:xs)
              proof <- expandAutoProof inite (e) it
              rmAssert
              return (DataAlt c, xs, proof)

makeDataConArgs v dc = mapM freshVar ts
  where
    ts = dataConInstOrigArgTys dc ats
    ats = snd $ splitTyConApp $ varType v


expandAutoProof :: CoreExpr -> CoreExpr -> Integer -> Pr CoreExpr
expandAutoProof inite e it
  =  do ams  <- ae_axioms  <$> get
        vs'  <- ae_vars    <$> get
        cts  <- ae_consts  <$> get
        ds   <- ae_assert  <$> get
        cmb  <- ae_cmb     <$> get
        lmap <- ae_lmap    <$> get
        e'   <- unANFExpr e

        foldM (\lm x -> (updateLMap lm (dummyLoc $ F.symbol x) x >> (ae_lmap <$> get))) lmap vs'

        let (vs, vlits)  = L.partition (`elem` readVars e') $ nub' vs'
        let allvs        = nub'  ((fst . aname <$> ams) ++ cts  ++ vs')
        let (cts', vcts) = L.partition (isFunctionType . varType) allvs
        let usedVs = nub' (vs++vcts)

        env    <- makeEnvironment ((L.\\) allvs usedVs) ((L.\\) vlits usedVs)
        ctors  <- mapM makeCtor cts'
        pvs    <- mapM makeVar usedVs
        le     <- makeGoalPredicate e'
        fn     <- freshFilePath
        axioms <- makeAxioms
        let sol = unsafePerformIO (solve $ makeQuery fn it le axioms ctors ds env pvs)
        return $ {-
          traceShow (
            "\n\nTo prove\n" ++ show (showpp le) ++
            "\n\nWe need \n" ++ show sol         ++
            "\n\nExpr =  \n" ++ show (toCore cmb inite sol)         ++
            "\n\n"
           ) $ -}
          traceShow "\nexpandedExpr\n" $ toCore cmb inite sol

nub' = L.nubBy (\v1 v2 -> F.symbol v1 == F.symbol v2)

-- TODO: merge this with the Bare.Axiom.hs
updateLMap :: LogicMap  -> LocSymbol -> Var -> Pr ()
updateLMap _ _ v | not (isFun $ varType v)
  = return ()
  where
    isFun (FunTy _ _)    = True
    isFun (ForAllTy _ t) = isFun t
    isFun  _             = False

updateLMap _ x vv
  = insertLogicEnv x' ys (applyArrow (val x) ys)
  where
    nargs = dropWhile isClassType $ ty_args $ toRTypeRep $ ((ofType $ varType vv) :: RRType ())

    ys = zipWith (\i _ -> symbol (("x" ++ show i) :: String)) [1..] nargs
    x' = simpleSymbolVar vv


insertLogicEnv x ys e
  = modify $ \be -> be {ae_lmap = (ae_lmap be) {logic_map = M.insert x (LMap x ys e) $ logic_map $ ae_lmap be}}

simpleSymbolVar  x = dropModuleNames $ symbol $ showPpr $ getName x

-------------------------------------------------------------------------------
----------------   From Haskell to Prover  ------------------------------------
-------------------------------------------------------------------------------





makeEnvironment :: [Var] -> [Var] -> Pr [P.LVar]
makeEnvironment avs vs
  = do lits <- ae_lits <$> get
       let lts'  = filter (\(x,_) -> not (x `elem` (F.symbol <$> avs))) (normalize lits)
       let lts1  = [P.Var x s () | (x, s) <- lts']
       lts2  <- mapM makeLVar vs
       return (lts1 ++ lts2)



makeQuery :: FilePath -> Integer -> F.Pred -> [HAxiom] -> [HVarCtor] -> [F.Pred] -> [P.LVar] ->  [HVar] -> HQuery
makeQuery fn i p axioms cts ds env vs
 = Query   { q_depth  = fromInteger i
           , q_goal   = P.Pred p

           , q_vars   = checkVar  <$> vs      -- local variables
           , q_ctors  = cts                   -- constructors: globals with function type
           , q_env    = checkEnv  <$> env     -- environment: anything else that can appear in the logic

           , q_fname  = fn
           , q_axioms = axioms
           , q_decls  = (P.Pred <$> ds)
           }

checkEnv pv@(P.Var x s _)
  | isBaseSort s = pv
  | otherwise    = errorstar ("\nEnv:\nNon Basic " ++ show x ++ "  ::  " ++ show s)

checkVar pv@(P.Var x s _)
  | isBaseSort s = pv
  | otherwise    = errorstar ("\nVar:\nNon Basic " ++ show x ++ "  ::  " ++ show s)

makeAxioms =
  do recs <- ae_recs    <$> get
     tce  <- ae_emb     <$> get
     sigs <- ae_sigs    <$> get
     gs   <- ae_globals <$> get
     let (rgs, gs') = L.partition (`elem` (fst <$> recs)) $ filter returnsProof gs
     let as1 = varToPAxiom tce sigs <$> gs'
     let as2 = varToPAxiomWithGuard tce sigs recs <$> rgs
     return (as1 ++ as2)

unANFExpr e = (foldl (flip Let) e . ae_binds) <$> get

makeGoalPredicate e =
  do lm   <- ae_lmap    <$> get
     case runToLogic lm (ErrOther (showSpan "makeGoalPredicate") . text) (coreToPred e) of
       Left p  -> return p
       Right (ErrOther _ err) -> error $ show err
       _                      -> error "makeGoalPredicate: panic"


makeRefinement :: Maybe SpecType -> [Var] -> F.Pred
makeRefinement Nothing  _ = F.PTrue
makeRefinement (Just t) xs = rr
  where trep = toRTypeRep t
        ys   = [x | (x, t') <- zip (ty_binds trep) (ty_args trep), not (isClassType t')]
        rr   = case stripRTypeBase $ ty_res trep of
                 Nothing  -> F.PTrue
                 Just ref -> let F.Reft(v, r) = F.toReft ref
                                 su = F.mkSubst $ zip (v:ys) (F.EVar . F.symbol <$> xs)
                             in F.subst su r



makeCtor :: Var -> Pr HVarCtor
makeCtor c
  = do tce  <- ae_emb     <$> get
       sigs <- ae_sigs    <$> get
       lmap <- ae_lmap    <$> get
       lvs  <- ae_vars    <$> get
       return $ makeCtor' tce lmap sigs (c `elem` lvs) c

makeCtor' :: F.TCEmb TyCon -> LogicMap -> [(F.Symbol, SpecType)] -> Bool -> Var -> HVarCtor
makeCtor' tce _ _ islocal  v | islocal
  = P.VarCtor (P.Var (F.symbol v) (typeSortArrow tce $ varType v) v) [] (P.Pred F.PTrue)

makeCtor' tce lmap sigs _  v
  = case M.lookup v (axiom_map lmap) of
    Nothing -> P.VarCtor (P.Var (F.symbol v) (typeSort tce $ varType v)      v) vs r
    Just x  -> P.VarCtor (P.Var x            (typeSortArrow tce $ varType v) v) [] (P.Pred F.PTrue)

  where
    x    = F.symbol v
    (vs, r) = case L.lookup x sigs of
                Nothing -> ([], P.Pred F.PTrue)
                Just t  -> let trep = toRTypeRep t
                           in case stripRTypeBase $ ty_res trep of
                               Nothing -> ([], P.Pred F.PTrue)
                               Just r  -> let (F.Reft(v, p)) = F.toReft r
                                              xts = [(x,t) | (x, t) <- zip (ty_binds trep) (ty_args trep), not $ isClassType t]
                                              e  = F.EApp (dummyLoc x) (F.EVar . fst  <$> xts)
                                          in ([P.Var x (rTypeSortArrow tce t) ()  | (x, t) <- xts], P.Pred $ F.subst1 p (v, e))

makeVar :: Var -> Pr HVar
makeVar v = do {tce <- ae_emb <$> get; return $ makeVar' tce v}

makeVar'  tce v = P.Var (F.symbol v) (typeSortArrow tce $ varType v) v

makeLVar :: Var -> Pr P.LVar
makeLVar v = do {tce <- ae_emb <$> get; return $ makeLVar' tce v}

makeLVar' tce v = P.Var (F.symbol v) (typeSortArrow tce $ varType v) ()



varToPAxiomWithGuard :: F.TCEmb TyCon -> [(Symbol, SpecType)] -> [(Var, [Var])] -> Var -> HAxiom
varToPAxiomWithGuard tce sigs recs v
  = P.Axiom { axiom_name = makeVar' tce v
            , axiom_vars = vs
            , axiom_body = P.Pred $ F.PImp q bd
            }
  where
    q = makeGuard $ zip (symbol <$> args) xts
    args = fromJust $ L.lookup v recs
    x = F.symbol v
    (vs, xts, bd) = case L.lookup x sigs of
                     Nothing -> error ("haxiomToPAxiom: " ++ show x ++ " not found")
                     Just t -> let trep = toRTypeRep t
                                   bd'  = case stripRTypeBase $ ty_res trep of
                                            Nothing -> F.PTrue
                                            Just r  -> let (F.Reft(_, p)) = F.toReft r in p
                                   xts   = filter (not . isClassType . snd) $ zip (ty_binds trep) (ty_args trep)
                                   vs'   = [P.Var x (rTypeSortArrow tce t) () | (x, t) <- xts]
                               in  (vs', xts, bd')

makeGuard :: [(F.Symbol, (F.Symbol, SpecType))] -> F.Pred
makeGuard xs = F.POr $ go [] xs
  where
    go _ []
      = []
    go acc ((x, (x', RApp c _ _ _)):xxs)
     | Just f <- sizeFunction $ rtc_info c
     = (F.PAnd (F.PAtom F.Lt (f x') (f x):acc)) : go (F.PAtom F.Le (f x') (f x):acc) xxs
    go acc (_:xxs)
     = go acc xxs


varToPAxiom :: F.TCEmb TyCon -> [(Symbol, SpecType)] -> Var -> HAxiom
varToPAxiom tce sigs v
  = P.Axiom { axiom_name = makeVar' tce v
            , axiom_vars = vs
            , axiom_body = P.Pred bd
            }
  where
    x = F.symbol v
    (vs, bd) = case L.lookup x sigs of
                Nothing -> error ("haxiomToPAxiom: " ++ show x ++ " not found")
                Just t -> let trep = toRTypeRep t
                              bd'  = case stripRTypeBase $ ty_res trep of
                                       Nothing -> F.PTrue
                                       Just r  -> let (F.Reft(_, p)) = F.toReft r in p
                              vs'   = [P.Var x (rTypeSortArrow tce t) () | (x, t) <- zip (ty_binds trep) (ty_args trep), not $ isClassType t]
                          in  (vs', bd')


-------------------------------------------------------------------------------
-------------  Proof State Environment ----------------------------------------
-------------------------------------------------------------------------------

type Pr = State AEnv

data AEnv = AE { ae_axioms  :: [T.HAxiom]            -- axiomatized functions
               , ae_binds   :: [CoreBind]            -- local bindings, tracked st they are expanded in logic
               , ae_lmap    :: LogicMap              -- logical mapping
               , ae_consts  :: [Var]                 -- Data constructors and imported variables
               , ae_globals :: [Var]                 -- Global definitions, like axioms
               , ae_vars    :: [Var]                 -- local variables in scope
               , ae_emb     :: F.TCEmb TyCon         -- type constructor information
               , ae_lits    :: [(Symbol, F.Sort)]    -- literals
               , ae_index   :: Integer               -- unique integer
               , ae_sigs    :: [(Symbol, SpecType)]  -- Refined type signatures
               , ae_target  :: FilePath              -- file name of target source coude
               , ae_recs    :: [(Var, [Var])]        -- axioms that are used recursively:
                                                     -- these axioms are guarded to used only with "smaller" arguments
               , ae_assert  :: [F.Pred]              --
               , ae_cmb     :: CoreExpr -> CoreExpr -> CoreExpr  -- how to combine proofs
               }


initAEEnv info sigs
    = do tce    <- tyConEmbed  <$> get
         lts    <- lits        <$> get
         i      <- freshIndex  <$> get
         modify $ \s -> s{freshIndex = i + 1}
         return $ AE { ae_axioms  = axioms spc
                     , ae_binds   = []
                     , ae_lmap    = logicMap spc
                     , ae_consts  = L.nub vs
                     , ae_globals = L.nub tp
                     , ae_vars    = []
                     , ae_emb     = tce
                     , ae_lits    = wiredSortedSyms ++ lts
                     , ae_index   = i
                     , ae_sigs    = sigs
                     , ae_target  = target info
                     , ae_recs    = []
                     , ae_assert  = []
                     , ae_cmb     = \x y -> (App (App (Var by) x) y)
                     }
    where
      spc        = spec info
      vs         = filter validVar (snd <$> freeSyms spc)
      tp         = filter validExp (defVars info)

      isExported = flip elemNameSet (exports $ spec info) . getName
      validVar   = not . canIgnore
      validExp x = validVar x && isExported x
      by         = makeCombineVar $ makeCombineType τProof
      τProof     = proofType $ spec info




addBind b     = modify $ \ae -> ae{ae_binds = b:ae_binds ae}
addAssert p   = modify $ \ae -> ae{ae_assert = p:ae_assert  ae}
rmAssert      = modify $ \ae -> ae{ae_assert = tail $ ae_assert ae}
addRec  (x,e) = modify $ \ae -> ae{ae_recs  = (x, grapArgs e):ae_recs  ae}
addRecs xes   = modify $ \ae -> ae{ae_recs  = [(x, grapArgs e) | (x, e) <- xes] ++ ae_recs  ae}

addVar  x | canIgnore x = return ()
          | otherwise   = modify $ \ae -> ae{ae_vars  = x:ae_vars  ae}


addVars x = modify $ \ae -> ae{ae_vars  = x' ++ ae_vars  ae}
  where
    x' = filter (not . canIgnore) x

getUniq :: Pr Integer
getUniq
  = do modify (\s -> s{ae_index = 1 + (ae_index s)})
       ae_index <$> get


freshVar :: Type -> Pr Var
freshVar t =
  do n <- getUniq
     return $ stringVar ("x" ++ show n) t

freshFilePath :: Pr FilePath
freshFilePath =
  do fn <- ae_target <$> get
     n  <- getUniq
     return $ (extFileName (Auto $ fromInteger n) fn)


-------------------------------------------------------------------------------
--------------  Playing with Fixpoint  ----------------------------------------
-------------------------------------------------------------------------------


isBaseSort (F.FFunc _ ss) = and $ map notFFunc ss
isBaseSort (F.FApp s1 s2) = isBaseSort s1 && isBaseSort s2
isBaseSort  _             = True

notFFunc (F.FFunc _ _) = False
notFFunc _ = True



-------------------------------------------------------------------------------
--------------  Playing with GHC Core  ----------------------------------------
-------------------------------------------------------------------------------

-- hasBaseType = isBaseTy . varType

isFunctionType (FunTy _ _)    = True
isFunctionType (ForAllTy _ t) = isFunctionType t
isFunctionType _              = False


resultType (ForAllTy _ t) = resultType t
resultType (FunTy _ t)    = resultType t
resultType  t             = t


grapArgs (Lam x e) | isTyVar x  = grapArgs e
grapArgs (Lam x e) | isClassPred $ varType x = grapArgs e
grapArgs (Lam x e) = x : grapArgs e
grapArgs (Let _ e) = grapArgs e
grapArgs _         = []



grapInt (Var v)
  = do bs <- ae_binds <$> get
       let (e:_) = [ex | NonRec x ex <- bs, x == v]
       return $ go e
  where
    go (Tick _ e) = go e
    go (App _ l)  = go l
    go (Lit l)    = litToInt l
    go e          = error $ ("grapInt called with wrong argument " ++ showPpr e)

    litToInt (MachInt i) = i
    litToInt (MachInt64 i) = i
    litToInt _             = error "litToInt: non integer literal"

grapInt (Tick _ e) = grapInt e
grapInt _          = return 2


-------------------------------------------------------------------------------
--------------------  Combine Proofs  ----------------------------------------
-------------------------------------------------------------------------------

makeCombineType Nothing
  = error "proofType not found"
makeCombineType (Just τ)
  = FunTy τ (FunTy τ τ)


makeCombineVar τ =  stringVar combineProofsName τ
-------------------------------------------------------------------------------
-------------------  Helper Functions  ----------------------------------------
-------------------------------------------------------------------------------

canIgnore v = isInternal v || isTyVar v
isAuto    v = isPrefixOfSym "auto"  $ dropModuleNames $ F.symbol v
isCases   v = isPrefixOfSym "cases" $ dropModuleNames $ F.symbol v
isProof   v = isPrefixOfSym "Proof" $ dropModuleNames $ F.symbol v


returnsProof :: Var -> Bool
returnsProof = isProof' . resultType . varType
  where
    isProof' (TyConApp tc _) = isProof tc
    isProof' _               = False


normalize xts = filter hasBaseSort $ L.nub xts
  where
    hasBaseSort = isBaseSort . snd


mapSndM act xys = mapM (\(x, y) -> (x,) <$> act y) xys
