
{-# LANGUAGE NoMonomorphismRestriction, TypeSynonymInstances, FlexibleInstances, TupleSections, DeriveDataTypeable, ScopedTypeVariables #-}

module Language.Haskell.Liquid.GhcInterface where

import GHC 
import Outputable
import HscTypes
import TidyPgm      (tidyProgram)
import CoreSyn
import Var
import TysWiredIn
import BasicTypes   (TupleSort(BoxedTuple), Arity)
import IdInfo
import Name         (getSrcSpan)
import CoreMonad    (liftIO)
import Serialized
import Annotations
import CorePrep
import VarEnv
import DataCon
import TyCon
import qualified TyCon as TC
import HscMain
import TypeRep
import Module
import Language.Haskell.Liquid.Desugar.HscMain (hscDesugarWithLoc) 
import MonadUtils (concatMapM, mapSndM)
import qualified Control.Exception as Ex

import GHC.Paths (libdir)
import System.FilePath (dropExtension, takeFileName, dropFileName, (</>)) 
import System.Directory (copyFile) 
import System.Environment (getArgs)
import DynFlags (defaultDynFlags, ProfAuto(..))
import Control.Monad (filterM)
import Control.Arrow hiding ((<+>))
import Control.DeepSeq
import Control.Applicative  hiding (empty)
import Control.Monad (forM_, forM, liftM, (>=>))
import Data.Data
import Data.Monoid hiding ((<>))
import Data.Char (isSpace)
import Data.List (intercalate, isPrefixOf, isSuffixOf, foldl', nub, find, splitAt, elemIndex, (\\))
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe)
import qualified Data.Set as S
import qualified Data.Map as M
import GHC.Exts         (groupWith, sortWith)
import TysPrim          (intPrimTyCon)
import TysWiredIn       (listTyCon, intTy, intTyCon, boolTyCon, intDataCon, trueDataCon, falseDataCon)

import System.Directory (doesFileExist)
import Language.Haskell.Liquid.Fixpoint hiding (Expr) 
import Language.Haskell.Liquid.Misc
import Language.Haskell.Liquid.FileNames
import Language.Haskell.Liquid.RefType
import Language.Haskell.Liquid.ANFTransform
import Language.Haskell.Liquid.Parse
import Language.Haskell.Liquid.Bare
import Language.Haskell.Liquid.PredType
import Language.Haskell.Liquid.GhcMisc

import qualified Language.Haskell.Liquid.Measure as Ms
import qualified Language.Haskell.Liquid.ACSS as ACSS
import qualified Language.Haskell.HsColour.CSS as CSS
import Language.Haskell.HsColour.Classify

------------------------------------------------------------------
---------------------- GHC Bindings:  Code & Spec ----------------
------------------------------------------------------------------


data GhcInfo = GI { 
    env      :: !HscEnv
  , cbs      :: ![CoreBind]
  , impVars  :: ![Var]
  , defVars  :: ![Var]
  , hqFiles  :: ![FilePath]
  , imports  :: ![String]
  , includes :: ![FilePath]
  , spec     :: !GhcSpec
  }

instance Outputable GhcSpec where
  ppr spec =  (text "******* Type Signatures *********************")
           $$ (ppr $ tySigs spec)
           $$ (text "******* DataCon Specifications (Measure) ****")
           $$ (ppr $ ctor spec)
           $$ (text "******* Measure Specifications **************")
           $$ (ppr $ meas spec)

instance Outputable GhcInfo where 
  ppr info =  (text "*************** Imports *********************")
           $$ (ppr $ imports info)
           $$ (text "*************** Includes ********************")
           $$ (ppr $ includes info)
           $$ (text "*************** Core Bindings ***************")
           $$ (ppr $ cbs info)
           $$ (text "*************** Imported Variables **********")
           $$ (ppr $ impVars info)
           $$ (text "*************** Defined Variables ***********")
           $$ (ppr $ defVars info)
           $$ (text "*************** Specification ***************")
           $$ (ppr $ spec info)

instance Show GhcInfo where
  show = showPpr 

------------------------------------------------------------------
-------------- Extracting CoreBindings From File -----------------
------------------------------------------------------------------

{- 
compileCore :: GhcMonad m => Bool -> FilePath -> m CoreModule
compileCore simplify fn = do
   -- First, set the target to the desired filename
   target <- guessTarget fn Nothing
   addTarget target
   _ <- load LoadAllTargets
   -- Then find dependencies
   modGraph <- depanal [] True
   case find ((== fn) . msHsFilePath) modGraph of
     Just modSummary -> do
       -- Now we have the module name;
       -- parse, typecheck and desugar the module
       mod_guts <- coreModule `fmap`
                      -- TODO: space leaky: call hsc* directly?
                      (desugarModule =<< typecheckModule =<< parseModule modSummary)
       liftM (gutsToCoreModule (mg_safe_haskell mod_guts)) $
         if simplify
          then do
             -- If simplify is true: simplify (hscSimplify), then tidy (tidyProgram).
             hsc_env <- getSession
             simpl_guts <- liftIO $ hscSimplify hsc_env mod_guts
             tidy_guts <- liftIO $ tidyProgram hsc_env simpl_guts
             return $ Left tidy_guts
          else
             return $ Right mod_guts

     Nothing -> panic "compileToCoreModule: target FilePath not found in\
                           module dependency graph"
  where -- two versions, based on whether we simplify (thus run tidyProgram,
        -- which returns a (CgGuts, ModDetails) pair, or not (in which case
        -- we just have a ModGuts.
        gutsToCoreModule :: SafeHaskellMode
                         -> Either (CgGuts, ModDetails) ModGuts
                         -> CoreModule
        gutsToCoreModule safe_mode (Left (cg, md)) = CoreModule {
          cm_module = cg_module cg,
          cm_types  = md_types md,
          cm_binds  = cg_binds cg,
          cm_safe   = safe_mode
        }
        gutsToCoreModule safe_mode (Right mg) = CoreModule {
          cm_module  = mg_module mg,
          cm_types   = typeEnvFromEntities (bindersOfBinds (mg_binds mg))
                                           (mg_tcs mg)
                                           (mg_fam_insts mg),
          cm_binds   = mg_binds mg,
          cm_safe    = safe_mode
         }
-}

updateDynFlags df ps 
  = df { importPaths  = ps ++ importPaths df  } 
       { libraryPaths = ps ++ libraryPaths df }
       { profAuto     = ProfAutoCalls         }

getGhcModGuts1 fn = do
   liftIO $ deleteBinFiles fn 
   target <- guessTarget fn Nothing
   addTarget target
   load LoadAllTargets
   modGraph <- depanal [] True
   case find ((== fn) . msHsFilePath) modGraph of
     Just modSummary -> do
       mod_guts <- coreModule `fmap` (desugarModuleWithLoc =<< typecheckModule =<< parseModule modSummary)
       return   $! (miModGuts mod_guts)

-- Generates Simplified ModGuts (INLINED, etc.) but without SrcSpan
getGhcModGutsSimpl1 fn = do
   liftIO $ deleteBinFiles fn 
   target <- guessTarget fn Nothing
   addTarget target
   load LoadAllTargets
   modGraph <- depanal [] True
   case find ((== fn) . msHsFilePath) modGraph of
     Just modSummary -> do
       mod_guts   <- coreModule `fmap` (desugarModule =<< typecheckModule =<< parseModule modSummary)
       hsc_env    <- getSession
       simpl_guts <- liftIO $ hscSimplify hsc_env mod_guts
       (cg,_)     <- liftIO $ tidyProgram hsc_env simpl_guts
       liftIO $ putStrLn "************************* CoreGuts ****************************************"
       liftIO $ putStrLn (showPpr $ cg_binds cg)
       return $! (miModGuts mod_guts) { mgi_binds = cg_binds cg } 

peepGHCSimple fn 
  = do z <- compileToCoreSimplified fn
       liftIO $ putStrLn "************************* peeGHCSimple Core Module ************************"
       liftIO $ putStrLn $ showPpr z
       liftIO $ putStrLn "************************* peeGHCSimple Bindings ***************************"
       liftIO $ putStrLn $ showPpr (cm_binds z)
       errorstar "Done peepGHCSimple"

getGhcInfo target paths 
  = runGhc (Just libdir) $ do
      df                 <- getSessionDynFlags
      setSessionDynFlags  $ updateDynFlags df paths
      -- peepGHCSimple target 
      modguts            <- getGhcModGuts1 target
      hscEnv             <- getSession
      -- modguts     <- liftIO $ hscSimplify hscEnv modguts
      coreBinds          <- liftIO $ anormalize hscEnv modguts
      let impvs           = importVars coreBinds 
      let defvs           = definedVars coreBinds 
      (spec, imps, incs) <- moduleSpec (impvs ++ defvs) target modguts paths 
      liftIO              $ putStrLn $ "Module Imports: " ++ show imps 
      hqualFiles         <- moduleHquals modguts paths target imps incs 
      return              $ GI hscEnv coreBinds impvs defvs hqualFiles imps incs spec 

moduleHquals mg paths target imps incs 
  = do hqs   <- specIncludes Hquals paths incs 
       hqs'  <- moduleImports [Hquals] paths (mgi_namestring mg : imps)
       let rv = sortNub $ hqs ++ (snd <$> hqs')
       liftIO $ putStrLn $ "Reading Qualifiers From: " ++ show rv 
       return rv

printVars s vs 
  = do putStrLn s 
       putStrLn $ showPpr [(v, getSrcSpan v) | v <- vs]

mgi_namestring = moduleNameString . moduleName . mgi_module

importVars  = freeVars S.empty 
definedVars = concatMap defs 
  where defs (NonRec x _) = [x]
        defs (Rec xes)    = map fst xes


instance Show TC.TyCon where
 show = showSDoc . ppr

--------------------------------------------------------------------------------
---------------------------- Desugaring (Taken from GHC) -----------------------
--------------------------------------------------------------------------------

desugarModuleWithLoc tcm = do
  let ms = pm_mod_summary $ tm_parsed_module tcm 
  -- let ms = modSummary tcm
  let (tcg, _) = tm_internals_ tcm
  hsc_env <- getSession
  let hsc_env_tmp = hsc_env { hsc_dflags = ms_hspp_opts ms }
  guts <- liftIO $ hscDesugarWithLoc hsc_env_tmp ms tcg
  return $ DesugaredModule { dm_typechecked_module = tcm, dm_core_module = guts }

--------------------------------------------------------------------------------
--------------- Extracting Specifications (Measures + Assumptions) -------------
--------------------------------------------------------------------------------
 
moduleSpec vars target mg paths
  = do liftIO      $ putStrLn ("paths = " ++ show paths) 
       tgtSpec    <- liftIO $ parseSpec (name, target) 
       _          <- liftIO $ checkAssertSpec vars             $ Ms.sigs       tgtSpec
       impSpec    <- getSpecs paths impNames [Spec, Hs, LHs] 
       let spec    = Ms.expandRTAliases $ tgtSpec `mappend` impSpec 
       let imps    = sortNub $ impNames ++ [symbolString x | x <- Ms.imports spec]
       setContext [IIModule (mgi_module mg)]
       env        <- getSession
       ghcSpec    <- liftIO $ makeGhcSpec vars env spec
       return      (ghcSpec, imps, Ms.includes tgtSpec)
    where impNames = allDepNames  mg
          name     = mgi_namestring mg

allDepNames mg    = allNames'
  where allNames' = sortNub impNames
        impNames  = moduleNameString <$> (depNames mg ++ dirImportNames mg) 

depNames       = map fst        . dep_mods      . mgi_deps
dirImportNames = map moduleName . moduleEnvKeys . mgi_dir_imps  
targetName     = dropExtension  . takeFileName 

getSpecs paths names exts
  = do fs    <- sortNub <$> moduleImports exts paths names 
       liftIO $ putStrLn ("getSpecs: " ++ show fs)
       transParseSpecs exts paths S.empty mempty fs

transParseSpecs _ _ _ spec []       
  = return spec
transParseSpecs exts paths seenFiles spec newFiles 
  = do newSpec   <- liftIO $ liftM mconcat $ mapM parseSpec newFiles 
       impFiles  <- moduleImports exts paths [symbolString x | x <- Ms.imports newSpec]
       let seenFiles' = seenFiles  `S.union` (S.fromList newFiles)
       let spec'      = spec `mappend` newSpec
       let newFiles'  = [f | f <- impFiles, f `S.notMember` seenFiles']
       transParseSpecs exts paths seenFiles' spec' newFiles'
 
parseSpec (name, file) 
  = Ex.catch (parseSpec' name file) $ \(e :: Ex.IOException) ->
      ioError $ userError $ "Hit exception: " ++ (show e) ++ " while parsing Spec file: " ++ file ++ " for module " ++ name 


parseSpec' name file 
  = do putStrLn $ "parseSpec: " ++ file ++ " for module " ++ name  
       str     <- readFile file
       let spec = specParser name file str
       return   $ spec 

specParser name file str  
  | isExtFile Spec file  = rr' file str
  | isExtFile Hs file    = hsSpecificationP name file str
  | isExtFile LHs file   = hsSpecificationP name file str
  | otherwise            = errorstar $ "specParser: Cannot Parse File " ++ file

--specParser Spec _  = rr'
--specParser Hs name = hsSpecificationP name

--moduleImports ext paths  = liftIO . liftM catMaybes . mapM (mnamePath paths ext) 
--mnamePath paths ext name = fmap (name,) <$> getFileInDirs file paths
--                           where file = name `extModuleName` ext

moduleImports exts paths 
  = liftIO . liftM concat . mapM (moduleFiles paths exts) 

moduleFiles paths exts name 
  = do files <- mapM (`getFileInDirs` paths) (extModuleName name <$> exts)
       return [(name, file) | Just file <- files]


--moduleImports ext paths names 
--  = liftIO $ liftM catMaybes $ forM extNames (namePath paths)
--    where extNames = (`extModuleName` ext) <$> names 
-- namePath paths fileName = getFileInDirs fileName paths

--namePath_debug paths name 
--  = do res <- getFileInDirs name paths
--       case res of
--         Just p  -> putStrLn $ "namePath: name = " ++ name ++ " expanded to: " ++ (show p) 
--         Nothing -> putStrLn $ "namePath: name = " ++ name ++ " not found in: " ++ (show paths)
--       return res

specIncludes :: GhcMonad m => Ext -> [FilePath] -> [FilePath] -> m [FilePath]
specIncludes ext paths reqs 
  = do let libFile  = extFileName ext preludeName
       let incFiles = catMaybes $ reqFile ext <$> reqs 
       liftIO $ forM (libFile : incFiles) (`findFileInDirs` paths)

reqFile ext s 
  | isExtFile ext s 
  = Just s 
  | otherwise
  = Nothing

checkAssertSpec :: [Var] -> [(Symbol, BareType)] -> IO () 
checkAssertSpec vs xbs =
  let vm  = M.fromList [(showPpr v, v) | v <- vs] 
      xs' = [s | (x, _) <- xbs, let s = symbolString x, not (M.member s vm)]
  in case xs' of 
    [] -> return () 
    _  -> errorstar $ "Asserts for Unknown variables: "  ++ (intercalate ", " xs')  
---------------------------------------------------------------
---------------- Annotations and Solutions --------------------
---------------------------------------------------------------

newtype AnnInfo a 
  = AI (M.Map SrcSpan (Maybe Var, a))
    deriving (Data, Typeable)

type Annot 
  = Either SpecType SrcSpan
    -- deriving (Data, Typeable)

instance Functor AnnInfo where
  fmap f (AI m) = AI (fmap (\(x, y) -> (x, f y)) m)

instance Outputable a => Outputable (AnnInfo a) where
  ppr (AI m) = vcat $ map pprAnnInfoBind $ M.toList m 
 

pprAnnInfoBind (RealSrcSpan k, xv) 
  = xd $$ ppr l $$ ppr c $$ ppr n $$ vd $$ text "\n\n\n"
    where l        = srcSpanStartLine k
          c        = srcSpanStartCol k
          (xd, vd) = pprXOT xv 
          n        = length $ lines $ showSDoc vd

pprAnnInfoBind (_, _) 
  = empty

pprXOT (x, v) = (xd, ppr v)
  where xd = maybe (text "unknown") ppr x

applySolution :: FixSolution -> AnnInfo RefType -> AnnInfo RefType 
applySolution = fmap . fmap . mapReft . map . appSolRefa 
  where appSolRefa _ ra@(RConc _) = ra 
        -- appSolRefa _ p@(RPvar _)  = p  
        appSolRefa s (RKvar k su) = RConc $ subst su $ M.findWithDefault PTop k s  
        mapReft f (Reft (x, zs))  = Reft (x, squishRas $ f zs)

squishRas ras  = (squish [p | RConc p <- ras]) : [] -- [ra | ra@(RPvar _) <- ras]
  where squish = RConc . pAnd . sortNub . filter (not . isTautoPred) . concatMap conjuncts   

conjuncts (PAnd ps)          = concatMap conjuncts ps
conjuncts p | isTautoPred p  = []
            | otherwise      = [p]


-------------------------------------------------------------------
------------------- Rendering Inferred Types ----------------------
-------------------------------------------------------------------

annotate :: FilePath -> FixSolution -> AnnInfo Annot -> IO ()
annotate fname sol anna 
  = do annotDump fname (extFileName Html $ extFileName Cst fname) annm
       annotDump fname (extFileName Html fname) annm'
    where annm = closeAnnots anna
          annm' = tidyRefType <$> applySolution sol annm

annotDump :: FilePath -> FilePath -> AnnInfo RefType -> IO ()
annotDump srcFile htmlFile ann 
  = do cssFile <- getCSSPath
       src     <- readFile srcFile
       -- | generate html
       let body = {-# SCC "hsannot" #-} ACSS.hsannot False (Just tokAnnot) lhs (src, mkAnnMap ann)
       writeFile htmlFile $ CSS.top'n'tail srcFile $! body
       -- | generate .annot
       copyFile srcFile annotFile
       appendFile annotFile $ show annm
       -- | copy .css file
       copyFile cssFile (dropFileName htmlFile </> takeFileName cssFile) 
    where annotFile = extFileName Annot srcFile
          annm      = mkAnnMap ann
          lhs       = isExtFile LHs srcFile  

mkAnnMap :: AnnInfo RefType -> ACSS.AnnMap
mkAnnMap (AI m) 
  = ACSS.Ann 
  $ M.fromList
  $ map (srcSpanLoc *** bindString)
  $ map (head . sortWith (srcSpanEndCol . fst)) 
  $ groupWith (lineCol . fst) 
  $ [ (l, m) | (RealSrcSpan l, m) <- M.toList m, oneLine l]  
  where bindString = mapPair (showSDocForUser neverQualify) . pprXOT 

srcSpanLoc l 
  = ACSS.L (srcSpanStartLine l, srcSpanStartCol l)
oneLine l  
  = srcSpanStartLine l == srcSpanEndLine l
lineCol l  
  = (srcSpanStartLine l, srcSpanStartCol l)

closeAnnots :: AnnInfo Annot -> AnnInfo RefType 
closeAnnots = fmap uRType' . closeA . filterA
  
closeA a@(AI m)  = cf <$> a 
  where cf (Right loc) = case m `mlookup` loc of
                           (_, Left t) -> t
                           _           -> errorstar $ "malformed AnnInfo: " ++ showPpr loc
        cf (Left t)    = t

filterA (AI m) = AI (M.filter ff m)
  where ff (_, Right loc) = loc `M.member` m
        ff _              = True


------------------------------------------------------------------------------
------------ Tokenizing RefTypes ---------------------------------------------
------------------------------------------------------------------------------

refToken = Keyword

tokAnnot s 
  = case trimLiquidAnnot s of 
      Just (l, body, r) -> [(refToken, l)] ++ tokBody body ++ [(refToken, r)]
      Nothing           -> [(Comment, s)]

trimLiquidAnnot ('{':'-':'@':ss) 
  | drop (length ss - 3) ss == "@-}"
  = Just ("{-@", take (length ss - 3) ss, "@-}") 
trimLiquidAnnot _  
  = Nothing

tokBody s 
  | isData s  = tokenise s
  | isType s  = tokenise s
  | isIncl s  = tokenise s
  | otherwise = {- traceShow ("tokBody: " ++ s) $ -} tokeniseSpec s 

isData = spacePrefix "data"
isType = spacePrefix "type"
isIncl = spacePrefix "include"

spacePrefix str s@(c:cs)
  | isSpace c   = spacePrefix str cs
  | otherwise   = (take (length str) s) == str
spacePrefix _ _ = False 


tokeniseSpec = tokAlt . chopAlt [('{', ':'), ('|', '}')] 
  where tokAlt (s:ss)  = tokenise s ++ tokAlt' ss
        tokAlt _       = []
        tokAlt' (s:ss) = (refToken, s) : tokAlt ss
        tokAlt' _      = []

------------------------------------------------------------------------------
-------------------------------- A CoreBind Visitor --------------------------
------------------------------------------------------------------------------

-- TODO: syb-shrinkage

class CBVisitable a where
  freeVars :: S.Set Var -> a -> [Var]
  readVars :: a -> [Var] 

instance CBVisitable [CoreBind] where
  freeVars env cbs = (sortNub xs) \\ ys 
    where xs = concatMap (freeVars env) cbs 
          ys = concatMap bindings cbs
  
  readVars cbs = concatMap readVars cbs  

instance CBVisitable CoreBind where
  freeVars env (NonRec x e) = freeVars (extendEnv env [x]) e 
  freeVars env (Rec xes)    = concatMap (freeVars env') es 
                              where (xs,es) = unzip xes 
                                    env'    = extendEnv env xs 

  readVars (NonRec x e)      = readVars e
  readVars (Rec xes)         = concatMap readVars $ map snd xes

instance CBVisitable (Expr Var) where
  freeVars env (Var x)         = if x `S.member` env then [] else [x]  
  freeVars env (App e a)       = (freeVars env e) ++ (freeVars env a)
  freeVars env (Lam x e)       = freeVars (extendEnv env [x]) e
  freeVars env (Let b e)       = (freeVars env b) ++ (freeVars (extendEnv env (bindings b)) e)
  freeVars env (Tick _ e)      = freeVars env e
  freeVars env (Cast e _)      = freeVars env e
  freeVars env (Case e x _ cs) = (freeVars env e) ++ (concatMap (freeVars (extendEnv env [x])) cs) 
  freeVars env (Lit _)         = []
  freeVars env (Type _)	       = []

  readVars (Var x)             = [x]
  readVars (App e a)           = concatMap readVars [e, a] 
  readVars (Lam x e)           = readVars e
  readVars (Let b e)           = readVars b ++ readVars e 
  readVars (Tick _ e)          = readVars e
  readVars (Cast e _)          = readVars e
  readVars (Case e _ _ cs)     = (readVars e) ++ (concatMap readVars cs) 
  readVars (Lit _)             = []
  readVars (Type _)	           = []


instance CBVisitable (Alt Var) where
  freeVars env (a, xs, e) = freeVars env a ++ freeVars (extendEnv env xs) e
  readVars (_,_, e)       = readVars e

instance CBVisitable AltCon where
  freeVars _ (DataAlt dc) = [dataConWorkId dc]
  freeVars _ _            = []
  readVars _              = []


names     = (map varName) . bindings

extendEnv = foldl' (flip S.insert)

bindings (NonRec x _) 
  = [x]
bindings (Rec  xes  ) 
  = map fst xes

---------------------------------------------------------------
------------------ Printing Related Functions -----------------
---------------------------------------------------------------

--instance Outputable Spec where
--  ppr (Spec s) = vcat $ map pprAnnot $ varEnvElts s 
--    where pprAnnot (x,r) = ppr x <> text " @@ " <> ppr r <> text "\n"

ppFreeVars    = showSDoc . vcat .  map ppFreeVar 
ppFreeVar x   = ppr n <> text " :: " <> ppr t <> text "\n" 
                where n = varName x
                      t = varType x

ppVarExp (x,e) = text "Var " <> ppr x <> text " := " <> ppr e
ppBlank = text "\n_____________________________\n"

--------------------------------------------------------------------
------ Strictness --------------------------------------------------
--------------------------------------------------------------------

instance NFData Var
instance NFData SrcSpan
instance NFData a => NFData (AnnInfo a) where
  rnf (AI x) = () -- rnf x

--instance NFData GhcInfo where
--  rnf (GI x1 x2 x3 x4 x5 x6 x7 x8 _ _ _) 
--    = {-# SCC "NFGhcInfo" #-} 
--      x1 `seq` 
--      x2 `seq` 
--      {- rnf -} x3 `seq` 
--      {- rnf -} x4 `seq` 
--      {- rnf -} x5 `seq` 
--      {- rnf -} x6 `seq` 
--      {- rnf -} x7 `seq` 
--      {- rnf -} x8

