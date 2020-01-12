{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Axel.Macros where

import Axel.Prelude

import Axel (isPrelude, preludeMacros)
import Axel.AST
  ( Expression(EFunctionApplication, EIdentifier, ERawExpression)
  , FunctionApplication(FunctionApplication)
  , FunctionDefinition(FunctionDefinition)
  , Identifier
  , ImportSpecification(ImportAll)
  , MacroDefinition
  , QualifiedImport(QualifiedImport)
  , RestrictedImport(RestrictedImport)
  , SMStatement
  , Statement(SFunctionDefinition, SMacroDefinition, SMacroImport,
          SMacroImport, SModuleDeclaration, SQualifiedImport,
          SQualifiedImport, SRawStatement, SRestrictedImport, STypeSignature)
  , ToHaskell(toHaskell)
  , TypeSignature(TypeSignature)
  , _SMacroDefinition
  , _SModuleDeclaration
  , functionDefinition
  , imports
  , moduleName
  , name
  , statementsToProgram
  )
import Axel.Denormalize (denormalizeStatement)
import qualified Axel.Eff as Effs
import Axel.Eff.Error (Error(MacroError, ParseError), fatal)
import qualified Axel.Eff.FileSystem as Effs (FileSystem)
import qualified Axel.Eff.FileSystem as FS
import qualified Axel.Eff.Ghci as Effs (Ghci)
import qualified Axel.Eff.Ghci as Ghci
import qualified Axel.Eff.Log as Effs (Log)
import Axel.Eff.Log (logStrLn)
import qualified Axel.Eff.Process as Effs (Process)
import qualified Axel.Eff.Restartable as Effs (Restartable)
import Axel.Eff.Restartable (restart, runRestartable)
import Axel.Haskell.Error (processStackOutputLine)
import Axel.Haskell.Macros (hygenisizeMacroName)
import Axel.Normalize
  ( normalizeExpression
  , normalizeStatement
  , unsafeNormalize
  , unsafeNormalize
  , withExprCtxt
  )
import Axel.Parse (parseMultiple)
import Axel.Parse.AST (_SExpression, bottomUpFmapSplicing, toAxel)
import qualified Axel.Parse.AST as Parse
import Axel.Sourcemap
  ( ModuleInfo
  , SourceMetadata
  , isCompoundExpressionWrapperHead
  , quoteSMExpression
  , renderSourcePosition
  , unwrapCompoundExpressions
  , wrapCompoundExpressions
  )
import qualified Axel.Sourcemap as SM
import Axel.Utils.FilePath ((<.>), (</>), replaceExtension, takeFileName)
import Axel.Utils.List (filterMap, filterMapOut, head')
import Axel.Utils.Recursion (bottomUpFmap, zipperTopDownTraverse)
import Axel.Utils.Zipper (unsafeLeft, unsafeUp)

import Control.Lens (_1, isn't, op, snoc)
import Control.Lens.Extras (is)
import Control.Lens.Operators ((%~), (^.), (^?))
import Control.Monad (guard, unless, when)
import Control.Monad.Extra (whenJust)

import Data.Function (on)
import Data.Generics.Uniplate.Zipper (Zipper, fromZipper, hole, replaceHole, up)
import Data.Hashable (hash)
import Data.List (intersperse, nub)
import Data.List.Extra (mconcatMap)
import Data.List.Split (split, whenElt)
import qualified Data.Map as M
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Type.Equality ((:~:)(Refl))

import qualified Language.Haskell.Ghcid as Ghcid

import qualified Polysemy as Sem
import qualified Polysemy.Error as Sem
import qualified Polysemy.Reader as Sem
import qualified Polysemy.State as Sem

type CompileFilesArgs a = [FilePath] -> a

type RunFileArgs a = FilePath -> a

-- NOTE We're not using `lens` with `Backend` since `makeFieldsNoPrefix`
--      _really_ doesn't like `Effs.Callback` (i.e. we start getting
--      "GHC doesn't yet support impredicative polymorphism", and even
--      after enabling the hacky `ImpredicativeTypes` extension, there are
--      still various type errors.
data Backend effs =
  Backend
    { compileFiles :: Effs.Callback effs CompileFilesArgs [Text]
    , wasCompileSuccessful :: [Text] -> Bool
    , extension :: Text
    , mkAutogeneratedImports :: FilePath -> [SMStatement]
    , mkComment :: Text -> Text
    , mkHeaderAndScaffold :: FilePath -> [SM.Expression] -> Identifier -> Identifier -> ( [SMStatement]
                                                                                        , [SMStatement])
    , mkMacroTypeSignature :: Identifier -> SMStatement
    , processCompilerOutputLine :: ModuleInfo -> Text -> [Text]
    , runFile :: Effs.Callback effs RunFileArgs Text
    , wasRunSuccessful :: Text -> Bool
    , symbolSubstitutions :: [(String, String)]
    }

haskellSymbolSubstitutions :: [(String, String)]
haskellSymbolSubstitutions = [("List", "[]"), ("Unit", "()"), ("unit", "()")]

haskellMkMacroTypeSignature :: Identifier -> SMStatement
haskellMkMacroTypeSignature =
  SRawStatement Nothing .
  (<> " :: [AST.Expression SM.SourceMetadata] -> GHCPrelude.IO [AST.Expression SM.SourceMetadata]")

haskellMkAutogeneratedImports :: FilePath -> [SMStatement]
haskellMkAutogeneratedImports filePath
            -- We can't import the Axel prelude if we're actually compiling it.
 =
  [ SRestrictedImport $ RestrictedImport Nothing "Axel" (ImportAll Nothing)
  | not $ isPrelude filePath
  ] <>
  [ SQualifiedImport $
    QualifiedImport Nothing "Prelude" "GHCPrelude" (ImportAll Nothing) -- (in case `-XNoImplicitPrelude` is enabled)
  , SQualifiedImport $
    QualifiedImport Nothing "Axel.Parse.AST" "AST" (ImportAll Nothing)
  ]

haskellMkHeaderAndScaffold ::
     FilePath
  -> [SM.Expression]
  -> Identifier
  -> Identifier
  -> ([SMStatement], [SMStatement])
haskellMkHeaderAndScaffold filePath args scaffoldModuleName macroDefAndEnvModuleName =
  let mkModuleDecl = SModuleDeclaration Nothing
      mkQualImport moduleName' alias =
        SQualifiedImport $
        QualifiedImport Nothing moduleName' alias (ImportAll Nothing)
      mkId = EIdentifier Nothing
      mkQualId moduleName' identifier =
        EIdentifier Nothing $ moduleName' <> "." <> identifier
      mkTySig fnName ty = STypeSignature $ TypeSignature Nothing fnName [] ty
      mkFnDef fnName args' body =
        SFunctionDefinition $ FunctionDefinition Nothing fnName args' body []
      mkFnApp fn args' =
        EFunctionApplication $ FunctionApplication Nothing fn args'
      mkRawExpr = ERawExpression Nothing
      mkList xs =
        mkFnApp (mkId "[") $ intersperse (mkRawExpr ",") xs <>
        [mkId "]"] -- This is VERY hacky, but it'll work without too much effort for now.
   in ( haskellMkAutogeneratedImports filePath <>
        [mkQualImport "Axel.Sourcemap" "SM"]
      , mkModuleDecl scaffoldModuleName : haskellMkAutogeneratedImports filePath <>
        [ mkQualImport macroDefAndEnvModuleName macroDefAndEnvModuleName
        , mkQualImport "Axel.Sourcemap" "SM"
        , mkTySig "main" $ mkFnApp (mkId "GHCPrelude.IO") [mkId "()"]
        , mkFnDef "main" [] $
          mkFnApp
            (mkId "(GHCPrelude.>>=)")
            [ mkFnApp
                (mkQualId
                   macroDefAndEnvModuleName
                   "main_AXEL_AUTOGENERATED_FUNCTION_DEFINITION")
                [ mkList
                    (map
                       (unsafeNormalize normalizeExpression . quoteSMExpression)
                       args)
                ]
            , mkFnApp
                (mkId "(GHCPrelude..)")
                [ mkId "GHCPrelude.putStrLn"
                , mkFnApp
                    (mkId "(GHCPrelude..)")
                    [ mkId "GHCPrelude.unlines"
                    , mkFnApp (mkId "GHCPrelude.map") [mkId "AST.toAxel'"]
                    ]
                ]
            ]
        ])

haskellCompileFiles ::
     (Sem.Members '[ Sem.Reader Ghcid.Ghci, Effs.Ghci] effs)
  => [FilePath]
  -> Sem.Sem effs [Text]
haskellCompileFiles files = do
  ghci <- Sem.ask
  Ghci.addFiles ghci files

haskellWasCompileSuccessful :: [Text] -> Bool
haskellWasCompileSuccessful = any ("Ok, " `T.isPrefixOf`)

haskellWasRunSuccessful :: Text -> Bool
haskellWasRunSuccessful = any ("*** Exception:" `T.isPrefixOf`) . T.lines

haskellMkComment :: Text -> Text
haskellMkComment = ("-- " <>)

type HaskellBackendEffs = '[ Effs.Ghci, Sem.Reader Ghcid.Ghci]

haskellBackend :: Backend HaskellBackendEffs
haskellBackend =
  Backend
    { compileFiles = haskellCompileFiles
    , wasCompileSuccessful = haskellWasCompileSuccessful
    , extension = ".hs"
    , mkAutogeneratedImports = haskellMkAutogeneratedImports
    , mkComment = haskellMkComment
    , mkHeaderAndScaffold = haskellMkHeaderAndScaffold
    , mkMacroTypeSignature = haskellMkMacroTypeSignature
    , processCompilerOutputLine = processStackOutputLine
    , runFile =
        \file -> do
          ghci <- Sem.ask @Ghcid.Ghci
          T.unlines <$> Ghci.exec ghci (op FilePath file <> ".main")
    , wasRunSuccessful = haskellWasRunSuccessful
    , symbolSubstitutions = haskellSymbolSubstitutions
    }

type FunctionApplicationExpanderArgs a = SM.Expression -> a

type FunctionApplicationExpander effs
   = Effs.Callback effs FunctionApplicationExpanderArgs (Maybe [SM.Expression])

type FileExpanderArgs a = FilePath -> a

type FileExpander effs = Effs.Callback effs FileExpanderArgs ()

-- By the time the function application expander callback will be called,
-- we'll have added these effects.
type SupportsFunAppExpanderEffs subEffs effs
   = Sem.Members subEffs (Sem.State [SMStatement] ': Effs.Restartable SM.Expression ': Sem.Reader FilePath ': effs)

-- | Fully expand a program, and add macro definition type signatures.
processProgram ::
     forall fileExpanderEffs funAppExpanderEffs backendEffs effs.
     ( Sem.Members '[ Sem.Error Error, Effs.Ghci, Sem.Reader Ghcid.Ghci, Sem.State ModuleInfo] effs
     , SupportsFunAppExpanderEffs fileExpanderEffs effs -- GHC refuses to compile if this is `Sem.Members fileExpanderEffs effs`, for some reason.
     , SupportsFunAppExpanderEffs funAppExpanderEffs effs
     )
  => Backend backendEffs
  -> (Backend backendEffs -> FunctionApplicationExpander funAppExpanderEffs)
  -> (Backend backendEffs -> FileExpander fileExpanderEffs)
  -> FilePath
  -> SM.Expression
  -> Sem.Sem effs [SMStatement]
processProgram backend expandFunApp expandFile filePath program = do
  newProgramExpr <-
    Sem.runReader filePath $
    expandProgramExpr
      @funAppExpanderEffs
      @fileExpanderEffs
      (expandFunApp backend)
      (expandFile backend)
      program
  newStmts <-
    mapM
      (Sem.runReader filePath . withExprCtxt . normalizeStatement)
      (unwrapCompoundExpressions newProgramExpr)
  withAstImports <-
    insertImports filePath (mkAutogeneratedImports backend filePath) newStmts
  pure $ finalizeProgram backend withAstImports

finalizeProgram :: Backend backendEffs -> [SMStatement] -> [SMStatement]
finalizeProgram backend stmts = do
  let expandQuotes =
        bottomUpFmapSplicing
          (\case
             Parse.SExpression _ (Parse.Symbol _ "quote":xs) ->
               map quoteSMExpression xs
             x -> [x])
      makeSymbolSubstitutions =
        bottomUpFmap $ \x ->
          case x of
            Parse.Symbol ann' sym ->
              case lookup sym (symbolSubstitutions backend) of
                Nothing -> x
                Just replacement -> Parse.Symbol ann' replacement
            _ -> x
      (nonMacroDefs, macroDefs) = filterMapOut (^? _SMacroDefinition) stmts
      hygenicMacroDefs = map hygenisizeMacroDefinition macroDefs
      toTopLevelStmts =
        map (unsafeNormalize normalizeStatement) . unwrapCompoundExpressions
      toProgramExpr = wrapCompoundExpressions . map denormalizeStatement
      macroTySigs = typeMacroDefinitions backend hygenicMacroDefs
   in toTopLevelStmts $ makeSymbolSubstitutions $ expandQuotes $ toProgramExpr $
      nonMacroDefs <>
      map SMacroDefinition hygenicMacroDefs <>
      macroTySigs

isMacroImported ::
     (Sem.Member (Sem.State [SMStatement]) effs)
  => Identifier
  -> Sem.Sem effs Bool
isMacroImported macroName = do
  let isFromPrelude = macroName `elem` preludeMacros
  isImportedDirectly <-
    any
      (\case
         SMacroImport macroImport -> macroName `elem` macroImport ^. imports
         _ -> False) <$>
    Sem.get
  pure $ isFromPrelude || isImportedDirectly

ensureCompiledDependency ::
     forall fileExpanderEffs effs.
     (Sem.Member (Sem.State ModuleInfo) effs, Sem.Members fileExpanderEffs effs)
  => FileExpander fileExpanderEffs
  -> Identifier
  -> Sem.Sem effs ()
ensureCompiledDependency expandFile dependencyName = do
  moduleInfo <-
    Sem.gets (M.filter (\(moduleId', _) -> moduleId' == dependencyName))
  case head' $ M.toList moduleInfo of
    Just (dependencyFilePath, (_, transpiledOutput)) ->
      when (isNothing transpiledOutput) $ expandFile dependencyFilePath
    Nothing -> pure ()

isStatementFocused :: Zipper SM.Expression SM.Expression -> Bool
isStatementFocused zipper =
  let wholeProgramExpr = fromZipper zipper
      isCompoundExpr = Just wholeProgramExpr == (hole <$> up zipper)
      isCompoundExprWrapper =
        case hole zipper of
          Parse.Symbol _ "begin" -> True
          _ -> False
   in isCompoundExpr && not isCompoundExprWrapper

-- | Fully expand a top-level expression.
--   Macro expansion is top-down: it proceeds top to bottom, outwards to inwards,
--   and left to right. Whenever a macro is successfully expanded to yield new
--   expressions in place of the macro call in question, the substitution is made
--   and macro expansion is repeated from the beginning. As new definitions, etc.
--   are found at the top level while the program tree is being traversed, they
--   will be added to the environment accessible to macros during expansion.
expandProgramExpr ::
     forall funAppExpanderEffs fileExpanderEffs effs innerEffs.
     ( innerEffs ~ (Sem.State [SMStatement] ': Effs.Restartable SM.Expression ': effs)
     , Sem.Members '[ Sem.Error Error, Sem.State ModuleInfo, Sem.Reader Ghcid.Ghci, Sem.Reader FilePath] effs
     , Sem.Members funAppExpanderEffs innerEffs
     , Sem.Members fileExpanderEffs innerEffs
     )
  => FunctionApplicationExpander funAppExpanderEffs
  -> FileExpander fileExpanderEffs
  -> SM.Expression
  -> Sem.Sem effs SM.Expression
expandProgramExpr expandFunApp expandFile programExpr =
  runRestartable @SM.Expression programExpr $
  Sem.evalState ([] :: [SMStatement]) .
  zipperTopDownTraverse
    (\zipper -> do
       when (isStatementFocused zipper) $
         -- NOTE This algorithm will exclude the last statement, but we won't
         --      have any macros that rely on it (since macros can only access
         --      what is before them in the file). Thus, this omission is okay.
         let prevTopLevelExpr = hole $ unsafeLeft zipper
          in unless (isCompoundExpressionWrapperHead prevTopLevelExpr) $
             addStatementToMacroEnvironment
               @fileExpanderEffs
               expandFile
               prevTopLevelExpr
       let expr = hole zipper
       when (is _SExpression expr) $ do
         maybeNewExprs <- expandFunApp expr
         case maybeNewExprs of
           Just newExprs -> replaceExpr zipper newExprs >>= restart
           Nothing -> pure ()
       pure expr)

-- | Returns the full program expr (after the necessary substitution has been applied).
replaceExpr ::
     (Sem.Members '[ Sem.Error Error, Sem.Reader FilePath] effs)
  => Zipper SM.Expression SM.Expression
  -> [SM.Expression]
  -> Sem.Sem effs SM.Expression
replaceExpr zipper newExprs =
  let programExpr = fromZipper zipper
      oldExpr = hole zipper
      -- NOTE Using `unsafeUp` is safe since `begin` cannot be the name of a macro,
      --      and thus `zipper` will never be focused on the whole program.
      oldParentExprZ = unsafeUp zipper
      newParentExpr =
        case hole oldParentExprZ of
          Parse.SExpression ann' xs ->
            let xs' = do
                  x <- xs
                  -- TODO What if there are multiple, equivalent copies of `oldExpr`?
                  --      If they are not top-level statements, then the macro in question
                  --      must already exist and thus we would have expanded it already.
                  --      If they are top-level statements, but e.g. were auto-generated, then
                  --      `==` will call them equal. If the macro in question did not exist
                  --      when the first statement was defined, but it does by the second
                  --      statement, then our result may be incorrect.
                  if x == oldExpr
                    then newExprs
                    else pure x
             in Parse.SExpression ann' xs'
          _ -> fatal "expandProgramExpr" "0001"
      newProgramExpr = fromZipper $ replaceHole newParentExpr oldParentExprZ
   in if newProgramExpr == programExpr
        then throwLoopError oldExpr newExprs
        else pure newProgramExpr

throwLoopError ::
     (Sem.Members '[ Sem.Error Error, Sem.Reader FilePath] effs)
  => SM.Expression
  -> [SM.Expression]
  -> Sem.Sem effs a
throwLoopError oldExpr newExprs = do
  filePath <- Sem.ask
  Sem.throw $
    MacroError
      filePath
      oldExpr
      ("Infinite loop detected during macro expansion!\nCheck that no macro calls expand (directly or indirectly) to themselves.\n" <>
       toAxel oldExpr <>
       " expanded into " <>
       T.unwords (map toAxel newExprs) <>
       ".")

addStatementToMacroEnvironment ::
     forall fileExpanderEffs effs.
     ( Sem.Members '[ Sem.Error Error, Sem.State ModuleInfo, Sem.Reader FilePath, Sem.State [SMStatement]] effs
     , Sem.Members fileExpanderEffs effs
     )
  => FileExpander fileExpanderEffs
  -> SM.Expression
  -> Sem.Sem effs ()
addStatementToMacroEnvironment expandFile newExpr = do
  filePath <- Sem.ask
  stmt <- Sem.runReader filePath $ withExprCtxt $ normalizeStatement newExpr
  let maybeDependencyName =
        case stmt of
          SRestrictedImport restrictedImport ->
            Just $ restrictedImport ^. moduleName
          SQualifiedImport qualifiedImport ->
            Just $ qualifiedImport ^. moduleName
          SMacroImport macroImport -> Just $ macroImport ^. moduleName
          _ -> Nothing
  whenJust maybeDependencyName $
    ensureCompiledDependency @fileExpanderEffs expandFile
  Sem.modify @[SMStatement] (`snoc` stmt)

type FunAppExpanderEffs
   = '[ Sem.Error Error, Effs.FileSystem, Effs.Ghci, Effs.Log, Effs.Process, Sem.State ModuleInfo, Sem.Reader Ghcid.Ghci, Sem.Reader FilePath, Sem.State [SMStatement]]

-- | If a function application is a macro call, expand it.
handleFunctionApplication ::
     forall backendEffs effs.
     ( Sem.Members FunAppExpanderEffs effs
     , Sem.Members backendEffs FunAppExpanderEffs
     )
  => Backend backendEffs
  -> SM.Expression
  -> Sem.Sem effs (Maybe [SM.Expression])
handleFunctionApplication backend fnApp@(Parse.SExpression ann (Parse.Symbol _ functionName:args)) = do
  shouldExpand <- isMacroCall $ T.pack functionName
  if shouldExpand
    then Just <$>
         withExpansionId
           fnApp
           (case Effs.prfMembersTransitive
                   @backendEffs
                   @FunAppExpanderEffs
                   @effs of
              Refl ->
                case Effs.prfMembersUnderCons
                       @(Sem.Reader ExpansionId)
                       @backendEffs
                       @effs of
                  Refl ->
                    (expandMacroApplication
                       @backendEffs
                       @(Sem.Reader ExpansionId ': effs)
                       backend
                       ann
                       (T.pack functionName)
                       args))
    else pure Nothing
handleFunctionApplication _ _ = pure Nothing

isMacroCall ::
     (Sem.Member (Sem.State [SMStatement]) effs)
  => Identifier
  -> Sem.Sem effs Bool
isMacroCall function = do
  localDefs <- lookupMacroDefinitions function
  let isDefinedLocally = not $ null localDefs
  isImported <- isMacroImported function
  pure $ isImported || isDefinedLocally

lookupMacroDefinitions ::
     (Sem.Member (Sem.State [SMStatement]) effs)
  => Identifier
  -> Sem.Sem effs [MacroDefinition (Maybe SM.Expression)]
lookupMacroDefinitions identifier =
  filterMap
    (\stmt -> do
       macroDef <- stmt ^? _SMacroDefinition
       guard $ identifier == (macroDef ^. functionDefinition . name)
       pure macroDef) <$>
  Sem.get

hygenisizeMacroDefinition :: MacroDefinition ann -> MacroDefinition ann
hygenisizeMacroDefinition = functionDefinition . name %~ hygenisizeMacroName

insertImports ::
     (Sem.Member (Sem.Error Error) effs)
  => FilePath
  -> [SMStatement]
  -> [SMStatement]
  -> Sem.Sem effs [SMStatement]
insertImports filePath newStmts program =
  case split (whenElt $ is _SModuleDeclaration) program of
    [preEnv, [moduleDecl@(SModuleDeclaration _ _)], postEnv] ->
      pure $ preEnv <> [moduleDecl] <> newStmts <> postEnv
    [preEnv, [moduleDecl@(SModuleDeclaration _ _)]] ->
      pure $ preEnv <> [moduleDecl] <> newStmts
    [[moduleDecl@(SModuleDeclaration _ _)], postEnv] ->
      pure $ [moduleDecl] <> newStmts <> postEnv
    [[moduleDecl@(SModuleDeclaration _ _)]] -> pure $ [moduleDecl] <> newStmts
    _ ->
      Sem.throw $
      ParseError
        filePath
        "Axel files must contain exactly one module declaration!"

newtype ExpansionId =
  ExpansionId Text

mkMacroDefAndEnvModuleName :: ExpansionId -> Identifier
mkMacroDefAndEnvModuleName (ExpansionId expansionId) =
  "AutogeneratedAxelMacroDefinitionAndEnvironment" <> expansionId

mkScaffoldModuleName :: ExpansionId -> Identifier
mkScaffoldModuleName (ExpansionId expansionId) =
  "AutogeneratedAxelScaffold" <> expansionId

generateMacroProgram ::
     forall backendEffs effs.
     (Sem.Members '[ Sem.Error Error, Effs.FileSystem, Sem.Reader ExpansionId, Sem.State [SMStatement]] effs)
  => Backend backendEffs
  -> FilePath
  -> Identifier
  -> [SM.Expression]
  -> Sem.Sem effs (SM.Output, SM.Output)
generateMacroProgram backend filePath' oldMacroName args = do
  macroDefAndEnvModuleName <- Sem.asks mkMacroDefAndEnvModuleName
  scaffoldModuleName <- Sem.asks mkScaffoldModuleName
  let newMacroName = hygenisizeMacroName oldMacroName
  let mainFnName = "main_AXEL_AUTOGENERATED_FUNCTION_DEFINITION"
  let footer =
        [ mkMacroTypeSignature backend mainFnName
        , SRawStatement Nothing $ mainFnName <> " = " <> newMacroName
        ]
  let (header, scaffold) =
        mkHeaderAndScaffold
          backend
          filePath'
          args
          scaffoldModuleName
          macroDefAndEnvModuleName
  prevStmts <- Sem.get @[SMStatement]
  -- Mitigate the `::`/`=`-ordering problem (see the description of issue #65).
  let auxEnv =
        reverse . dropWhile (isn't _SMacroDefinition) . reverse $ prevStmts
  -- TODO If the file being transpiled has pragmas but no explicit module declaration,
  --      they will be erroneously included *after* the module declaration.
  --      Should we just require Axel files to have module declarations, or is there a
  --      less intrusive alternate solution?
  macroDefAndEnv <-
    do let moduleDecl = SModuleDeclaration Nothing macroDefAndEnvModuleName
       programStmts <-
         insertImports filePath' header $ replaceModuleDecl moduleDecl $ auxEnv <>
         footer
       pure $ finalizeProgram backend programStmts
  pure $
    uncurry
      ((,) `on` toHaskell . statementsToProgram)
      (scaffold, macroDefAndEnv)
  where
    replaceModuleDecl newModuleDecl stmts =
      if any (is _SModuleDeclaration) stmts
        then map
               (\case
                  SModuleDeclaration _ _ -> newModuleDecl
                  x -> x)
               stmts
        else newModuleDecl : stmts

typeMacroDefinitions ::
     Backend backendEffs -> [MacroDefinition ann] -> [SMStatement]
typeMacroDefinitions backend macroDefs =
  map (mkMacroTypeSignature backend) $ getMacroNames macroDefs
  where
    getMacroNames = nub . map (^. functionDefinition . name)

-- | Source metadata is lost.
--   Use only for logging and such where that doesn't matter.
losslyReconstructMacroCall :: Identifier -> [SM.Expression] -> SM.Expression
losslyReconstructMacroCall macroName args =
  Parse.SExpression
    Nothing
    (Parse.Symbol Nothing (T.unpack macroName) : map (Nothing <$) args)

withExpansionId ::
     SM.Expression
  -> Sem.Sem (Sem.Reader ExpansionId ': effs) a
  -> Sem.Sem effs a
withExpansionId originalCall x =
  let expansionId = showText $ abs $ hash originalCall -- We take the absolute value so that folder names don't start with dashes
                                                       -- (it looks weird, even though it's not technically wrong).
                                                       -- In theory, this allows for collisions, but the chances are negligibly small(?).
   in Sem.runReader (ExpansionId expansionId) x

expandMacroApplication ::
     forall backendEffs effs.
     ( Sem.Members '[ Sem.Error Error, Effs.FileSystem, Effs.Ghci, Effs.Log, Effs.Process, Sem.Reader ExpansionId, Sem.Reader Ghcid.Ghci, Sem.Reader FilePath, Sem.State [SMStatement]] effs
     , Sem.Members backendEffs effs
     )
  => Backend backendEffs
  -> SourceMetadata
  -> Identifier
  -> [SM.Expression]
  -> Sem.Sem effs [SM.Expression]
expandMacroApplication backend originalAnn macroName args = do
  logStrLn $ "Expanding: " <> toAxel (losslyReconstructMacroCall macroName args)
  filePath' <- Sem.ask @FilePath
  macroProgram <- generateMacroProgram backend filePath' macroName args
  (tempFilePath, newSource) <-
    uncurry (evalMacro backend originalAnn macroName args) macroProgram
  logStrLn $ "Result: " <> newSource <> "\n\n"
  parseMultiple (Just tempFilePath) newSource

isMacroDefinitionStatement :: Statement ann -> Bool
isMacroDefinitionStatement (SMacroDefinition _) = True
isMacroDefinitionStatement _ = False

evalMacro ::
     forall backendEffs effs.
     ( Sem.Members '[ Sem.Error Error, Effs.FileSystem, Effs.Ghci, Effs.Process, Sem.Reader Ghcid.Ghci, Sem.Reader FilePath, Sem.Reader ExpansionId] effs
     , Sem.Members backendEffs effs
     )
  => Backend backendEffs
  -> SourceMetadata
  -> Identifier
  -> [SM.Expression]
  -> SM.Output
  -> SM.Output
  -> Sem.Sem effs (FilePath, Text)
evalMacro backend originalCallAnn macroName args scaffoldProgram macroDefAndEnvProgram = do
  macroDefAndEnvModuleName <- Sem.asks mkMacroDefAndEnvModuleName
  scaffoldModuleName <- Sem.asks mkScaffoldModuleName
  tempDir <- getTempDirectory
  let macroDefAndEnvFileName =
        tempDir </> FilePath macroDefAndEnvModuleName <.> extension backend
  let scaffoldFileName =
        tempDir </> FilePath scaffoldModuleName <.> extension backend
  let resultFile = tempDir </> FilePath "result.axel"
  FS.writeFile scaffoldFileName scaffold
  FS.writeFile macroDefAndEnvFileName macroDefAndEnv
  let moduleInfo =
        M.fromList $
        map
          (_1 %~ flip replaceExtension "axel")
          [ (scaffoldFileName, (scaffoldModuleName, Just scaffoldProgram))
          , ( macroDefAndEnvFileName
            , (macroDefAndEnvModuleName, Just macroDefAndEnvProgram))
          ]
  compileResult <-
    compileFiles backend [scaffoldFileName, macroDefAndEnvFileName]
  if wasCompileSuccessful backend compileResult
    then do
      result <- runFile backend scaffoldFileName
      let expansionRecord =
            generateExpansionRecord
              backend
              originalCallAnn
              macroName
              args
              result
              scaffoldFileName
              macroDefAndEnvFileName
      FS.writeFile resultFile expansionRecord
      if wasRunSuccessful backend result
        then throwMacroError result
        else pure (resultFile, result)
    else throwMacroError $ mconcat $
         mconcatMap (processCompilerOutputLine backend moduleInfo) compileResult
  where
    macroDefAndEnv = SM.raw macroDefAndEnvProgram
    scaffold = SM.raw scaffoldProgram
    getTempDirectory = do
      ExpansionId expansionId <- Sem.ask @ExpansionId
      let dirName = FilePath "axelTemp" </> FilePath expansionId
      FS.createDirectoryIfMissing True dirName
      pure dirName
    throwMacroError msg = do
      originalFilePath <- Sem.ask @FilePath
      Sem.throw $
        MacroError
          originalFilePath
          (losslyReconstructMacroCall macroName args)
          msg

generateExpansionRecord ::
     Backend backendEffs
  -> SourceMetadata
  -> Identifier
  -> [SM.Expression]
  -> Text
  -> FilePath
  -> FilePath
  -> Text
generateExpansionRecord backend originalAnn macroName args result scaffoldFilePath macroDefAndEnvFilePath =
  T.unlines
    [ result
    , mkComment
        backend
        "This file is an autogenerated record of a macro call and expansion."
    , mkComment
        backend
        "It is (likely) not a valid Axel program, so you probably don't want to run it directly."
    , ""
    , mkComment
        backend
        "The beginning of this file contains the result of the macro invocation at " <>
      locationHint <>
      ":"
    , toAxel (losslyReconstructMacroCall macroName args)
    , ""
    , mkComment backend $ "The macro call itself is transpiled in " <>
      op FilePath (takeFileName scaffoldFilePath) <>
      "."
    , ""
    , mkComment backend $
      "To see the (transpiled) modules, definitions, extensions, etc. visible during the expansion, check " <>
      op FilePath (takeFileName macroDefAndEnvFilePath) <>
      "."
    ]
  where
    locationHint =
      case originalAnn of
        Just x -> renderSourcePosition x
        Nothing -> "<unknown>"
