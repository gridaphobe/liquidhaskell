{-# LANGUAGE DeriveDataTypeable, FlexibleInstances, UndecidableInstances #-}

module Language.Haskell.Liquid.Fixpoint (
    toFixpoint
  , Fixpoint (toFix) 
  , typeSort, typeUniqueSymbol
  , symChars, isNonSymbol, nonSymbol, dummySymbol, intSymbol, tagSymbol, tempSymbol
  , stringTycon, stringSymbol, symbolString
  , anfPrefix, tempPrefix
  , intKvar
  , PVar (..), Sort (..), Symbol(..), Constant (..), Bop (..), Brel (..), Expr (..)
  , Pred (..), Refa (..), SortedReft (..), Reft(..)
  , SEnv (..)
  , FEnv
  , SubC (..), WfC(..), FixResult (..), FixSolution, FInfo (..)
  , emptySEnv, fromListSEnv, insertSEnv, deleteSEnv, lookupSEnv
  , insertFEnv 
  , vv
  , trueReft, trueSortedReft 
  , trueRefa
  , canonReft, exprReft, notExprReft, symbolReft
  , isNonTrivialSortedReft
  , isTautoReft
  , ppr_reft, ppr_reft_pred, flattenRefas
  , simplify, pAnd, pOr, pIte
  , emptySubst, mkSubst, catSubst
  , Subable (..)
  , isPredInReft
  , rmRPVar, rmRPVarReft, replacePVarReft
  ) where

import TypeRep 
import PrelNames (intTyConKey, intPrimTyConKey, integerTyConKey, boolTyConKey)

import TysWiredIn       (listTyCon)
import TyCon            (isTupleTyCon, tyConUnique)
import Outputable
import Control.Monad.State
import Text.Printf
import Data.Monoid hiding ((<>))
import Data.Functor
import Data.List    hiding (intersperse)
import Data.Char        (ord, chr, isAlphaNum, isAlpha, isUpper, toLower)
import qualified Data.Map as M
import qualified Data.Set as S
import Text.Parsec.String

import Data.Generics.Schemes
import Data.Generics.Aliases
import Data.Data    hiding (tyConName)
import Data.Maybe (catMaybes)

import Language.Haskell.Liquid.Misc
import Language.Haskell.Liquid.FileNames
import Language.Haskell.Liquid.GhcMisc

import qualified Data.Text as T

import Control.DeepSeq

-- type Output = SDoc -- T.Text

class Fixpoint a where
  toFix    :: a -> SDoc

  simplify :: a -> a 
  simplify =  id

--------------------------------------------------------------------
------------------ Predicate Variables -----------------------------
--------------------------------------------------------------------

data PVar t
  = PV { pname :: !Symbol
       , ptype :: !t
       , pargs :: ![(t, Symbol, Symbol)]
       }
	deriving (Data, Typeable, Show)

instance Eq (PVar t) where
  pv == pv' = (pname pv == pname pv') {- UNIFY: What about: && eqArgs pv pv' -}

instance Ord (PVar t) where
  compare (PV n _ _)  (PV n' _ _) = compare n n'

instance Functor PVar where
  fmap f (PV x t txys) = PV x (f t) (mapFst3 f <$> txys)

instance (NFData a) => NFData (PVar a) where
  rnf (PV n t txys) = rnf n `seq` rnf t `seq` rnf txys

--instance Subable (PVar a) where
--  subst su (PV p t args) = PV p t $ [(t, x, subst su y) | (t, x, y) <- args]
--
--instance MapSymbol (PVar a) where 
--  mapSymbol f (PV p t args) = PV (f p) t [(t, x, f y) | (t, x, y) <- args]

instance Show Type where
  show  = showSDoc . ppr

{-
------------------------------------------------------------
------------------- Sanitizing Symbols ---------------------
------------------------------------------------------------

data FxInfo = FxInfo { 
    symMap     :: !(M.Map Symbol Symbol)
  , constants  :: !(S.Set (Symbol, Sort, Bool))  -- Bool : whether to generate qualifiers for constant 
  , locMap     :: !(M.Map Loc Loc) 
  , freshIdx   :: !Integer }

type Fx     = State FxInfo

cleanLocs    :: (Data a) => a -> Fx a
cleanLocs = {-# SCC "CleanLocs" #-} everywhereM (mkM swiz)
  where swiz l@(FLoc x)
          | isFixSym x = return l
          | otherwise  = freshLoc l  
        swiz l = return l

freshLoc ::  Loc -> Fx Loc
freshLoc x 
  = do s <- get
       case M.lookup x $ locMap s of
         Nothing -> do let n = freshIdx s 
                       let y = FLoc ("ty_" ++ show n) 
                       put $ s {freshIdx = n + 1} { locMap = M.insert x y $ locMap s}
                       return y 
         Just y  -> return y

cleanSymbols :: (Data a) => a -> Fx a
cleanSymbols = {-# SCC "CleanSyms" #-} everywhereM (mkM swiz)
  where swiz s@(S x) 
          | isFixSym x = return s
          | otherwise  = freshSym s

freshSym ::  Symbol -> Fx Symbol
freshSym x = do 
  s <- get
  case M.lookup x $ symMap s of
    Nothing -> do let n = freshIdx s
                  let y = tempSymbol "fx" n 
                  put $ s {freshIdx = n + 1} { symMap = M.insert x y $ symMap s}
                  return y 
    Just y  -> return y
-}

isPredInReft p (Reft(_, ls)) = or (isPredInRefa p <$> ls)
isPredInRefa p (RPvar p')    = isSamePvar p p'
isPredInRefa _ _             = False


isSamePvar p1@(PV s1 t1 a1) p2@(PV s2 t2 a2) 
  | s1 == s2 
  = if True -- t1==t2 
     then if chkSameTyArgs a1 a2 
           then True
           else error $ 
              "isSamePvar: same var with different tys in args" ++ 
              show (p1, p2)
     else error $
        "isSamePvar: same var with different sorts" ++ show (p1, p2)
  | otherwise 
  = False 

chkSameTyArgs a1 a2
  = True -- and $ zipWith (==) ts1 ts2
  where ts1 = map (\(t, _, _) -> t) a1
        ts2 = map (\(t, _, _) -> t) a2

replacePVarReft (p, r) (Reft(v, rs)) 
  = Reft(v, concatMap (replaceRPvarRefa (RPvar p, r)) rs)
replaceRPvarRefa (r1@(RPvar(PV n1 _ ar)), Reft(v, rs)) (RPvar (PV n2 _ _))
  | n1 == n2
  = map (subst (pArgsToSub ar)) rs
  | otherwise
  = rs
replaceRPvarRefa _ r = [r]

rmRPVar s r = fst $ rmRPVarReft s r
rmRPVarReft s (Reft(v, ls)) = (Reft(v, ls'), su)
  where (l, s1) = unzip $ map (rmRPVarRefa s) ls
        ls' = catMaybes l
        su = case catMaybes s1 of {[su] -> su; _ -> error "Fixpoint.rmRPVarReft"}

rmRPVarRefa p1@(PV s1 t1 a1) r@(RPvar p2@(PV s2 t2 a2))
  | s1 == s2
  = (Nothing, Just $ pArgsToSub a2)
  | otherwise
  = (Just r, Nothing) 
rmRPVarRefa _ r
  = (Just r, Nothing)

pArgsToSub a = mkSubst $ map (\(_, s1, s2) -> (s1, EVar s2)) a

--strsToRefa n as = RConc $ PBexp $ (EApp (S n) ([EVar (S "VV")] ++ (map EVar as)))
--strToRefa n xs = RKvar n (Su (M.fromList xs))
--strToReft n xs = Reft (S "VV", [strToRefa n xs])
--strsToReft n as = Reft (S "VV", [strsToRefa n as])
--
--refaInReft k (Reft(v, ls)) = any (cmpRefa k) ls
--
--cmpRefa (RConc (PBexp (EApp (S n) _))) (RConc (PBexp (EApp (S n') _))) 
--  = n == n'
--cmpRefa _ _ 
--  = False
--
--replaceSorts (p, Reft(_, rs)) (Reft(v, ls))
--  = Reft(v, concatMap (replaceS (p, rs)) ls)
--
--replaceSort (p, k) (Reft(v, ls)) = Reft (v, (concatMap (replaceS (p, [k])) ls))
--
---- replaceS :: (Refa a, [Refa a]) -> Refa a -> [Refa a] 
--replaceS ((RKvar (S n) (Su s)), k) (RKvar (S n') (Su s')) 
--  | n == n'
--  = map (addSubs (Su s')) k -- [RKvar (S m) (Su (s `M.union` s1 `M.union` s'))]
--replaceS (k, v) p = [p]
--
--addSubs s ra@(RKvar k s') = RKvar k (unionTransSubs s s')
--addSubs _ f = f
--
---- union s1 s2 with transitivity : 
---- (x, z) in s1 and (z, y) in s2 => (x, y) in s
--unionTransSubs (Su s1) (Su s2) 
--  = Su $ (\(su1, su2) -> su1 `M.union` su2)(M.foldWithKey f (s1, s2) s1)
--  where f k (EVar v) (s1, s2) 
--          = case M.lookup v s2 of 
--            Just (EVar x) -> (M.adjust (\_ -> EVar x) k s1, M.delete v s2)
--            _             -> (s1, s2)
--        f _ _ s12 = s12

getConstants :: (Data a) => a -> [(Symbol, Sort, Bool)]
getConstants = everything (++) ([] `mkQ` f)
  where f (EDat s so) = [(s, so, True)]
        f (ELit s so) = [(s, so, False)]
        f _           = []



infoConstant (c, so, _)
  = text "constant" <+> toFix c <+> text ":" <+> toFix so <> blankLine <> blankLine 

{- {{{ 
infoConstant (c, so, b)
  | b 
  = vcat [d1, d2, d3] $+$ dn
  | otherwise 
  = d1 $+$ dn 
  where d1 = text "constant" <+> d <+> text ":" <+> toFix so  
        dn = text "\n\n" 
        d  = toFix c
        d2 = text "qualif TEQ" <> d <> text "(v:ptr) : (" <> tg <> text "([v]) =  " <> d <> text ")" 
        d3 = text "qualif TNE" <> d <> text "(v:ptr) : (" <> tg <> text "([v]) !=  " <> d <> text ")" 
        tg = text tagName
}}} -}

---------------------------------------------------------------
---------- Converting Constraints to Fixpoint Input -----------
---------------------------------------------------------------

instance Fixpoint a => Fixpoint [a] where
  toFix xs = brackets $ sep $ punctuate (text ";") (fmap toFix xs)
  simplify = map simplify

instance (Fixpoint a, Fixpoint b) => Fixpoint (a,b) where
  toFix   (x,y)  = (toFix x) <+> text ":" <+> (toFix y)
  simplify (x,y) = (simplify x, simplify y) 

data FInfo a = FI { cs :: ![SubC a]
                  , ws :: ![WfC a ] 
                  , gs :: !FEnv -- Envt Symbol, Sort)] 
                  } deriving (Data, Typeable)

toFixpoint x' = gsDoc x' $+$ conDoc x' $+$  csDoc x' $+$ wsDoc x'
  where conDoc     = vcat . map infoConstant . S.elems . S.fromList . getConstants 
        csDoc      = vcat . map toFix . cs 
        wsDoc      = vcat . map toFix . ws 
        gsDoc      = vcat . map infoConstant . map (\(x, (RR so _)) -> (x, so, False)) . M.assocs . (\(SE e) -> e) . gs
       
----------------------------------------------------------------------
---------------------------------- Sorts -----------------------------
----------------------------------------------------------------------

newtype Tycon = TC Symbol deriving (Eq, Ord, Data, Typeable, Show)

data Sort = FInt 
          | FBool
          | FNum                 -- numeric kind for Num tyvars
          | FObj  Symbol         -- uninterpreted type
          | FVar  !Int           -- fixpoint type variable
          | FFunc !Int ![Sort]   -- type-var arity, in-ts ++ [out-t]
          | FApp Tycon [Sort]    -- constructed type 
	      deriving (Eq, Ord, Data, Typeable, Show)

typeSort :: Type -> Sort 
typeSort (TyConApp c [])
  | k == intTyConKey     = FInt
  | k == intPrimTyConKey = FInt
  | k == integerTyConKey = FInt 
  | k == boolTyConKey    = FBool
  where k = tyConUnique c

typeSort (ForAllTy _ τ) 
  = typeSort τ  -- JHALA: Yikes! Fix!!!
typeSort (FunTy τ1 τ2) 
  = typeSortFun τ1 τ2
typeSort (TyConApp c τs)
  = FApp (stringTycon $ tyConName c) (typeSort <$> τs)
typeSort τ
  = FObj $ typeUniqueSymbol τ
  
tyConName c 
  | listTyCon == c = listConName
  | isTupleTyCon c = tupConName
  | otherwise      = showPpr c

isListTC (TC (S c)) = c == listConName

typeSortFun τ1 τ2
  = FFunc n $ genArgSorts sos
  where sos  = typeSort <$> τs
        τs   = τ1  : grabArgs [] τ2
        n    = (length sos) - 1
     
typeUniqueSymbol :: Type -> Symbol 
typeUniqueSymbol = stringSymbol . {- ("sort_" ++) . -} showSDocDump . ppr

grabArgs τs (FunTy τ1 τ2 ) = grabArgs (τ1:τs) τ2
grabArgs τs τ              = reverse (τ:τs)

genArgSorts :: [Sort] -> [Sort]
genArgSorts xs = zipWith genIdx xs $ memoIndex genSort xs
  where genSort FInt        = Nothing
        genSort FBool       = Nothing 
        genSort so          = Just so
        genIdx  _ (Just i)  = FVar i
        genIdx  so  _       = so

newtype Sub = Sub [(Int, Sort)]

instance Fixpoint Sort where
  toFix = toFix_sort

toFix_sort (FVar i)     = text "@"   <> parens (ppr i)
toFix_sort FInt         = text "int"
toFix_sort FBool        = text "bool"
toFix_sort (FObj x)     = toFix x -- text "ptr" <> parens (toFix x)
toFix_sort FNum         = text "num"
toFix_sort (FFunc n ts) = text "func" <> parens ((ppr n) <> (text ", ") <> (toFix ts))
toFix_sort (FApp c [t]) 
  | isListTC c          = brackets $ toFix_sort t 
toFix_sort (FApp c ts)  = toFix c <+> intersperse space (fp <$> ts)
                          where fp s@(FApp c (_:_)) = parens $ toFix_sort s 
                                fp s                = toFix_sort s


instance Fixpoint Tycon where
  toFix (TC s)       = toFix s

---------------------------------------------------------------
---------------------------- Symbols --------------------------
---------------------------------------------------------------

symChars 
  =  ['a' .. 'z']
  ++ ['A' .. 'Z'] 
  ++ ['0' .. '9'] 
  ++ ['_', '%', '.', '#']

data Symbol = S !String 
              deriving (Eq, Ord, Data, Typeable)

instance Fixpoint Symbol where
  toFix (S x) = text x

instance Outputable Symbol where
  ppr (S x) = text x 

instance Show Symbol where
  show (S x) = x

newtype Subst  = Su (M.Map Symbol Expr) 
                 deriving (Eq, Ord, Data, Typeable)

{-
newtype PSubst = PSu (M.Map PredVar Reft) 
                 deriving (Eq, Ord, Data, Typeable)
-}

instance Outputable Refa where
  ppr  = text . show

instance Outputable Expr where
  ppr  = text . show

instance Outputable Subst where
  ppr (Su m) = ppr (M.toList m)

instance Show Subst where
  show = showPpr

instance Fixpoint Subst where
  toFix (Su m) = case M.toAscList m of 
                   []  -> empty
                   xys -> hcat $ map (\(x,y) -> brackets $ (toFix x) <> text ":=" <> (toFix y)) xys


---------------------------------------------------------------------------
------ Converting Strings To Fixpoint ------------------------------------- 
---------------------------------------------------------------------------

stringTycon :: String -> Tycon
stringTycon = TC . stringSymbol . dropModuleNames

stringSymbol :: String -> Symbol
stringSymbol s
  | isFixSym' s = S s 
  | otherwise   = S $ fixSymPrefix ++ concatMap encodeChar s

symbolString :: Symbol -> String
symbolString (S str) 
  = case chopPrefix fixSymPrefix str of
      Just s  -> concat $ zipWith tx [0..] $ chunks s 
      Nothing -> str
    where chunks = unIntersperse symSep 
          tx i s = if even i then s else [decodeStr s]


okSymChars
  =  ['a' .. 'z']
  ++ ['A' .. 'Z'] 
  ++ ['0' .. '9'] 
  ++ ['_', '.'  ]
 

symSep = '#'
fixSymPrefix = "fix" ++ [symSep]


isFixSym' (c:cs) = isAlpha c && all (`elem` (symSep:okSymChars)) cs
isFixSym' _      = False
isFixSym (c:cs) = isAlpha c && all (`elem` okSymChars) cs
isFixSym _      = False

encodeChar c 
  | c `elem` okSymChars 
  = [c]
  | otherwise
  = [symSep] ++ (show $ ord c) ++ [symSep]

decodeStr s 
  = chr ((read s) :: Int)

---------------------------------------------------------------------

vv                      = S "VV"
dummySymbol             = S dummyName
tagSymbol               = S tagName
intSymbol x i           = S $ x ++ show i           

tempSymbol              ::  String -> Integer -> Symbol
tempSymbol prefix n     = intSymbol (tempPrefix ++ prefix) n

isTempSym (S x)         = tempPrefix `isPrefixOf` x
tempPrefix              = "lq_tmp_"
anfPrefix               = "lq_anf_" 
nonSymbol               = S ""
isNonSymbol             = (0 ==) . length . symbolString

intKvar                 :: Integer -> Symbol
intKvar                 = intSymbol "k_" 

---------------------------------------------------------------
------------------------- Expressions -------------------------
---------------------------------------------------------------

data Constant = I !Integer 
              deriving (Eq, Ord, Data, Typeable, Show)

data Brel = Eq | Ne | Gt | Ge | Lt | Le 
            deriving (Eq, Ord, Data, Typeable, Show)

data Bop  = Plus | Minus | Times | Div | Mod    
            deriving (Eq, Ord, Data, Typeable, Show)
	    -- NOTE: For "Mod" 2nd expr should be a constant or a var *)

data Expr = ECon !Constant 
          | EVar !Symbol
          | EDat !Symbol !Sort
          | ELit !Symbol !Sort
          | EApp !Symbol ![Expr]
          | EBin !Bop !Expr !Expr
          | EIte !Pred !Expr !Expr
          | ECst !Expr !Sort
          | EBot
          deriving (Eq, Ord, Data, Typeable, Show)

instance Fixpoint Integer where
  toFix = pprShow 

instance Fixpoint Constant where
  toFix (I i) = pprShow i


instance Fixpoint Brel where
  toFix Eq = text "="
  toFix Ne = text "!="
  toFix Gt = text ">"
  toFix Ge = text ">="
  toFix Lt = text "<"
  toFix Le = text "<="

instance Fixpoint Bop where
  toFix Plus  = text "+"
  toFix Minus = text "-"
  toFix Times = text "*"
  toFix Div   = text "/"
  toFix Mod   = text "mod"

instance Fixpoint Expr where
  toFix (ECon c)       = toFix c 
  toFix (EVar s)       = toFix s
  toFix (EDat s _)     = toFix s 
  toFix (ELit s _)     = toFix s
  toFix (EApp f es)    = (toFix f) <> (parens $ toFix es) 
  toFix (EBin o e1 e2) = parens $ toFix e1 <+> toFix o <+> toFix e2
  toFix (EIte p e1 e2) = parens $ toFix p <+> text "?" <+> toFix e1 <+> text ":" <+> toFix e2 
  toFix (ECst e so)    = parens $ toFix e <+> text " : " <+> toFix so 
  toFix (EBot)         = text "_|_"

----------------------------------------------------------
--------------------- Predicates -------------------------
----------------------------------------------------------

data Pred = PTrue
          | PFalse
          | PAnd  ![Pred]
          | POr   ![Pred]
          | PNot  !Pred
          | PImp  !Pred !Pred
          | PIff  !Pred !Pred
          | PBexp !Expr
          | PAtom !Brel !Expr !Expr
          | PAll  ![(Symbol, Sort)] !Pred
          | PTop
          deriving (Eq, Ord, Data, Typeable, Show)

instance Fixpoint Pred where
  toFix PTop            = text "???"
  toFix PTrue           = text "true"
  toFix PFalse          = text "false"
  toFix (PBexp e)       = parens $ text "?" <+> toFix e
  toFix (PNot p)        = parens $ text "~" <+> parens (toFix p)
  toFix (PImp p1 p2)    = parens $ (toFix p1) <+> text "=>" <+> (toFix p2)
  toFix (PIff p1 p2)    = parens $ (toFix p1) <+> text "<=>" <+> (toFix p2)
  toFix (PAnd ps)       = text "&&" <+> toFix ps
  toFix (POr  ps)       = text "||" <+> toFix ps
  toFix (PAtom r e1 e2) = parens $ toFix e1 <+> toFix r <+> toFix e2
  toFix (PAll xts p)    = text "forall" <+> (toFix xts) <+> text "." <+> (toFix p)

  simplify (PAnd [])    = PTrue
  simplify (POr  [])    = PFalse
  simplify (PAnd [p])   = simplify p
  simplify (POr  [p])   = simplify p
  simplify (PAnd ps)    
    | any isContra ps   = PFalse
    | otherwise         = PAnd $ map simplify ps
  simplify (POr  ps)    
    | any isTauto ps    = PTrue
    | otherwise         = POr  $ map simplify ps 
  simplify p            
    | isContra p        = PFalse
    | isTauto  p        = PTrue
    | otherwise         = p

zero         = ECon (I 0)
one          = ECon (I 1)
isContra     = (`elem` [ PAtom Eq zero one, PAtom Eq one zero, PFalse])   
isTauto      = (`elem` [ PTrue ])
hasTag e1 e2 = PAtom Eq (EApp tagSymbol [e1]) e2

isTautoReft (Reft (_, ras)) = all isTautoRa ras
isTautoRa (RConc p)         = isTauto p
isTautoRa _                 = False

pAnd          = simplify . PAnd 
pOr           = simplify . POr 
pIte p1 p2 p3 = pAnd [p1 `PImp` p2, (PNot p1) `PImp` p3] 

ppr_reft (Reft (v, ras)) d 
  | all isTautoRa ras
  = d
  | otherwise
  = braces (ppr v <+> colon <+> d <+> text "|" <+> ppRas ras)

--ppr_reft_preds rs 
--  | all isTautoReft rs 
--  = empty
--  | otherwise 
--  = angleBrackets $ hsep $ punctuate comma $ ppr_reft_pred <$> rs
 
ppr_reft_pred (Reft (v, ras))
  | all isTautoRa ras
  = text "true"
  | otherwise
  = ppRas ras

ppRas = cat . punctuate comma . map toFix . flattenRefas



---------------------------------------------------------------
----------------- Refinements and Environments  ---------------
---------------------------------------------------------------

data Refa 
  = RConc !Pred 
  | RKvar !Symbol !Subst
  | RPvar !(PVar Type)
  deriving (Eq, Ord, Data, Typeable, Show)

data Reft  -- t 
  = Reft (Symbol, [Refa]) 
  deriving (Eq, Ord, Data, Typeable) 

instance Show Reft where
  show (Reft x) = showSDoc $ toFix x 

instance Outputable Reft where
  ppr = ppr_reft_pred --text . show

data SortedReft
  = RR !Sort !Reft
  deriving (Eq, Ord, Data, Typeable) 

isNonTrivialSortedReft (RR _ (Reft (_, ras)))
  = not $ null ras

newtype SEnv a = SE (M.Map Symbol a) 
                 deriving (Eq, Ord, Data, Typeable) 

fromListSEnv            = SE . M.fromList
deleteSEnv x (SE env)   = SE (M.delete x env)
insertSEnv x y (SE env) = SE (M.insert x y env)
lookupSEnv x (SE env)   = M.lookup x env
emptySEnv               = SE M.empty
memberSEnv x (SE env)   = M.member x env
domainSEnv (SE env)     = M.keys env

instance Functor SEnv where
  fmap f (SE m) = SE $ fmap f m

type FEnv = SEnv SortedReft 

-- Envt (M.Map Symbol SortedReft) 
-- deriving (Eq, Ord, Data, Typeable) 
instance Fixpoint (PVar Type) where
  toFix (PV s so a) 
   = parens $ toFix s <+> sep (toFix . thd3 <$> a)

{-
--   = toFix s <+> (char ':') <+> ppr so <+> braces (toFixArgs a)

toFixArgs a 
  = sep $ punctuate (char ',') $
      map (\(s, s1, s2) ->
          toFix s1 <+> (char ':') <+> ppr s <+> text ":=" <+> toFix s2
          ) a
-}

instance Fixpoint Refa where
  toFix (RConc p)    = toFix p
  toFix (RKvar k su) = toFix k <> toFix su
  toFix (RPvar p)    = toFix p

instance Fixpoint SortedReft where
  toFix (RR so (Reft (v, ras))) 
    = braces 
    $ (toFix v) <+> (text ":") <+> (toFix so) <+> (text "|") <+> toFix ras

instance Fixpoint FEnv where
  toFix (SE m)  = toFix (M.toAscList m)

deleteFEnv   = deleteSEnv
fromListFEnv = fromListSEnv
emptyFEnv    = emptySEnv
insertFEnv   = insertSEnv . lower 
  where lower x@(S (c:cs)) 
          | isUpper c = S $ (toLower c):cs
          | otherwise = x

instance (Outputable a) => Outputable (SEnv a) where
  ppr (SE e) = vcat $ map pprxt $ M.toAscList e
	where pprxt (x, t) = ppr x <+> dcolon <+> ppr t

instance Outputable (SEnv a) => Show (SEnv a) where
  show = showSDoc . ppr

-----------------------------------------------------------------------------------
------------------------- Refinements and Environments ----------------------------
-----------------------------------------------------------------------------------

data SubC a = SubC { senv  :: !FEnv
                   , sgrd  :: !Pred
                   , slhs  :: !SortedReft
                   , srhs  :: !SortedReft
                   , sid   :: !(Maybe Integer)
                   , stag  :: ![Int] 
                   , sinfo :: !a
                   } deriving (Eq, Ord, Data, Typeable)

data WfC a  = WfC  { wenv  :: !FEnv
                   , wrft  :: !SortedReft
                   , wid   :: !(Maybe Integer) 
                   , winfo :: !a
                   } deriving (Eq, Ord, Data, Typeable)

data FixResult a = Crash [a] String | Safe | Unsafe ![a] | UnknownError

type FixSolution = M.Map Symbol Pred

instance Monoid (FixResult a) where
  mempty                          = Safe
  mappend Safe x                  = x
  mappend x Safe                  = x
  mappend _ c@(Crash _ _)         = c 
  mappend c@(Crash _ _) _         = c 
  mappend (Unsafe xs) (Unsafe ys) = Unsafe (xs ++ ys)
 
instance Outputable a => Outputable (FixResult (SubC a)) where
  ppr (Crash xs msg) = text "Crash! "  <> ppr (sinfo `fmap` xs) <> parens (text msg) 
  ppr Safe          = text "Safe"
  ppr (Unsafe xs)   = text "Unsafe: " <> ppr (sinfo `fmap` xs)

toFixPfx s x     = text s <+> toFix x

instance Show (SubC a) where
  show = showPpr 

instance Outputable (SubC a) where
  ppr = toFix 

instance Outputable (WfC a) where
  ppr = toFix 

instance Fixpoint (SubC a) where
  toFix c     = hang (text "\n\nconstraint:") 2 bd
     where bd =   text "env" <+> toFix (senv c) 
              $+$ text "grd" <+> toFix (sgrd c) 
              $+$ text "lhs" <+> toFix (slhs c) 
              $+$ text "rhs" <+> toFix (srhs c)
              $+$ (pprId (sid c) <+> pprTag (stag c)) 

instance Fixpoint (WfC a) where 
  toFix w     = hang (text "\n\nwf:") 2 bd 
    where bd  =   text "env"  <+> toFix (wenv w)
              $+$ text "reft" <+> toFix (wrft w) 
              $+$ pprId (wid w)

pprId (Just i)  = text "id" <+> (text $ show i)
pprId _         = text ""

pprTag []       = text ""
pprTag is       = text "tag" <+> toFix is 

instance Fixpoint Int where
  toFix = ppr

-------------------------------------------------------
------------------- Substitutions ---------------------
-------------------------------------------------------

class Subable a where
  subst  :: Subst -> a -> a

  subst1 :: a -> (Symbol, Expr) -> a
  subst1 thing (x, e) = subst (Su $ M.singleton x e) thing

instance Subable Symbol where
  subst (Su s) x           = subSymbol (M.lookup x s) x

subSymbol (Just (EVar y)) _ = y
subSymbol Nothing         x = x
subSymbol _               _ = error "sub Symbol"

instance Subable Expr where
  subst su (EApp f es)     = EApp f $ map (subst su) es 
  subst su (EBin op e1 e2) = EBin op (subst su e1) (subst su e2)
  subst su (EIte p e1 e2)  = EIte (subst su p) (subst su e1) (subst  su e2)
  subst su (ECst e so)     = ECst (subst su e) so
  subst (Su s) e@(EVar x)  = M.findWithDefault e x s
  subst su e               = e

instance Subable Pred where
  subst su (PAnd ps)       = PAnd $ map (subst su) ps
  subst su (POr  ps)       = POr  $ map (subst su) ps
  subst su (PNot p)        = PNot $ subst su p
  subst su (PImp p1 p2)    = PImp (subst su p1) (subst su p2)
  subst su (PIff p1 p2)    = PIff (subst su p1) (subst su p2)
  subst su (PBexp e)       = PBexp $ subst su e
  subst su (PAtom r e1 e2) = PAtom r (subst su e1) (subst su e2)
  subst su p@(PAll _ _)    = errorstar $ "subst: FORALL" 
  subst su p               = p

instance Subable Refa where
  subst su (RConc p)     = RConc   $ subst su p
  subst su (RKvar k su') = RKvar k $ su' `catSubst` su 
  subst su (RPvar p)     = RPvar p

instance (Subable a, Subable b) => Subable (a,b) where
  subst su (x,y) = (subst su x, subst su y)

instance Subable a => Subable [a] where
  subst su = map $ subst su

instance Subable a => Subable (M.Map k a) where
  subst su = M.map $ subst su

instance Subable Reft where
  subst su (Reft (v, ras)) = Reft (v, subst su ras)

instance Monoid Reft where
  mempty  = trueReft
  mappend (Reft (v, ras)) (Reft (v', ras')) 
    | v == v'   = Reft (v, ras ++ ras')
    | otherwise = Reft (v, ras ++ (ras' `subst1` (v', EVar v)))


instance Subable SortedReft where
  subst su (RR so r) = RR so $ subst su r

emptySubst 
  = Su M.empty

catSubst (Su s1) (Su s2) 
  = Su $ s1' `M.union` s2
    where s1' = subst (Su s2) `M.map` s1

mkSubst = Su . M.fromList

------------------------------------------------------------
------------- Generally Useful Refinements -----------------
------------------------------------------------------------

symbolReft = exprReft . EVar 

exprReft e    = Reft (vv, [RConc $ PAtom Eq (EVar vv) e])
notExprReft e = Reft (vv, [RConc $ PAtom Ne (EVar vv) e])

trueSortedReft :: Sort -> SortedReft
trueSortedReft = (`RR` trueReft) 

trueReft = Reft (vv, [])

trueRefa = RConc PTrue

canonReft r@(Reft (v, ras)) 
  | v == vv    = r 
  | otherwise = Reft (vv, ras `subst1` (v, EVar vv))

flattenRefas ::  [Refa] -> [Refa]
flattenRefas = concatMap flatRa
  where flatRa (RConc p) = RConc <$> flatP p
        flatRa ra        = [ra]
        flatP  (PAnd ps) = concatMap flatP ps
        flatP  p         = [p]

----------------------------------------------------------------
---------------------- Strictness ------------------------------
----------------------------------------------------------------

instance NFData Symbol where
  rnf (S x) = rnf x

--instance NFData Loc where
--  rnf (FLoc x) = rnf x
--  rnf (FLvar x) = rnf x

instance NFData Tycon where
  rnf (TC c)       = rnf c

instance NFData Sort where
  rnf (FVar x)     = rnf x
  rnf (FFunc n ts) = rnf n `seq` (rnf <$> ts) `seq` () 
  rnf (FApp c ts)  = rnf c `seq` (rnf <$> ts) `seq` ()
  rnf (z)          = z `seq` ()

instance NFData Sub where
  rnf (Sub x) = rnf x

instance NFData Subst where
  rnf (Su x) = rnf x

instance NFData FEnv where
  rnf (SE x) = rnf x

instance NFData Constant where
  rnf (I x) = rnf x

instance NFData Brel 
instance NFData Bop

instance NFData Expr where
  rnf (ECon x)        = rnf x
  rnf (EVar x)        = rnf x
  rnf (EDat x1 x2)    = rnf x1 `seq` rnf x2
  rnf (ELit x1 x2)    = rnf x1 `seq` rnf x2
  rnf (EApp x1 x2)    = rnf x1 `seq` rnf x2
  rnf (EBin x1 x2 x3) = rnf x1 `seq` rnf x2 `seq` rnf x3
  rnf (EIte x1 x2 x3) = rnf x1 `seq` rnf x2 `seq` rnf x3
  rnf (ECst x1 x2)    = rnf x1 `seq` rnf x2
  rnf (_)             = ()

instance NFData Pred where
  rnf (PAnd x)         = rnf x
  rnf (POr  x)         = rnf x
  rnf (PNot x)         = rnf x
  rnf (PBexp x)        = rnf x
  rnf (PImp x1 x2)     = rnf x1 `seq` rnf x2
  rnf (PIff x1 x2)     = rnf x1 `seq` rnf x2
  rnf (PAll x1 x2)     = rnf x1 `seq` rnf x2
  rnf (PAtom x1 x2 x3) = rnf x1 `seq` rnf x2 `seq` rnf x3
  rnf (_)              = ()

instance NFData Refa where
  rnf (RConc x)     = rnf x
  rnf (RKvar x1 x2) = rnf x1 `seq` rnf x2
  rnf (RPvar x)     = () -- rnf x

instance NFData Reft where 
  rnf (Reft (v, ras)) = rnf v `seq` rnf ras

instance NFData SortedReft where 
  rnf (RR so r) = rnf so `seq` rnf r

instance (NFData a) => NFData (SubC a) where
  rnf (SubC x1 x2 x3 x4 x5 x6 x7) 
    = rnf x1 `seq` rnf x2 `seq` rnf x3 `seq` rnf x4 `seq` rnf x5 `seq` rnf x6 `seq` rnf x7

instance (NFData a) => NFData (WfC a) where
  rnf (WfC x1 x2 x3 x4) 
    = rnf x1 `seq` rnf x2 `seq` rnf x3 `seq` rnf x4

class MapSymbol a where
  mapSymbol :: (Symbol -> Symbol) -> a -> a

instance MapSymbol Refa where
  mapSymbol f (RConc p)    = RConc (mapSymbol f p)
  mapSymbol f (RKvar s su) = RKvar (f s) su
  mapSymbol f (RPvar p)    = RPvar p -- RPvar (mapSymbol f p)

instance MapSymbol Reft where
  mapSymbol f (Reft(s, rs)) = Reft(f s, map (mapSymbol f) rs)

instance MapSymbol Pred where
  mapSymbol f (PAnd ps)       = PAnd (mapSymbol f <$> ps)
  mapSymbol f (POr ps)        = POr (mapSymbol f <$> ps)
  mapSymbol f (PNot p)        = PNot (mapSymbol f p)
  mapSymbol f (PImp p1 p2)    = PImp (mapSymbol f p1) (mapSymbol f p2)
  mapSymbol f (PIff p1 p2)    = PIff (mapSymbol f p1) (mapSymbol f p2)
  mapSymbol f (PBexp e)       = PBexp (mapSymbol f e)
  mapSymbol f (PAtom b e1 e2) = PAtom b (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (PAll _ _)      = error "mapSymbol PAll"
  mapSymbol _ p               = p 

instance MapSymbol Expr where
  mapSymbol f (EVar s)       = EVar $ f s
  mapSymbol f (EDat s so)    = EDat (f s) so
  mapSymbol f (ELit s so)    = ELit (f s) so
  mapSymbol f (EApp s es)    = EApp (f s) (mapSymbol f <$> es)
  mapSymbol f (EBin b e1 e2) = EBin b (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (EIte p e1 e2) = EIte (mapSymbol f p) (mapSymbol f e1) (mapSymbol f e2)
  mapSymbol f (ECst e s)     = ECst (mapSymbol f e) s 
  mapSymbol _ e              = e

