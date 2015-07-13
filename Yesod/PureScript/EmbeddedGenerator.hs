{-# LANGUAGE QuasiQuotes, TemplateHaskell, DataKinds, OverloadedStrings, TupleSections #-}
-- | Embed compiled purescript into the 'EmbeddedStatic' subsite.
--
-- This module provides an alternative way of embedding purescript code into a yesod application,
-- and is orthogonal to the support in "Yesod.PureScript".
--
-- To use this module, you should place all your purescript code into a single directory as files
-- with a @purs@ extension.  Next, you should use <http://bower.io/ bower> to manage purescript
-- dependencies.  You can then give your directory and all dependency directories to the generators
-- below.  (At the moment, you must list each dependency explicitly.  A future improvement is to
-- parse bower.json to find dependencies.)
--
-- For example, after installing bootstrap, purescript-either, and purescript-maybe using bower and
-- then adding purescript code to a directory called @myPurescriptDir@, you could use code such as the
-- following to create a static subsite.
--
-- >import Yesod.EmbeddedStatic
-- >import Yesod.PureScript.EmbeddedGenerator
-- >
-- >#ifdef DEVELOPMENT
-- >#define DEV_BOOL True
-- >#else
-- >#define DEV_BOOL False
-- >#endif
-- >mkEmbeddedStatic DEV_BOOL "myStatic" [
-- > 
-- >   purescript "js/mypurescript.js" uglifyJs ["MyPurescriptModule"]
-- >     [ "myPurescriptDir"
-- >     , "bower_components/purescript-either/src"
-- >     , "bower_components/purescript-maybe/src"
-- >     ]
-- > 
-- >  , embedFileAt "css/bootstrap.min.css" "bower_components/bootstrap/dist/boostrap.min.css"
-- >  , embedDirAt "fonts" "bower_components/bootstrap/dist/fonts"
-- >]
--
-- The result is that a variable `js_mypurescript_js` of type @Route EmbeddedStatic@ will be created
-- that when accessed will contain the javascript generated by the purescript compiler.  Assuming
-- @StaticR@ is your route to the embdedded static subsite, you can then reference these routes
-- using:
--
-- >someHandler :: Handler Html
-- >someHandler = defaultLayout $ do
-- >    addStylesheet $ StaticR css_bootstrap_min_css
-- >    addScript $ StaticR js_mypurescript_js
-- >    ...
--
module Yesod.PureScript.EmbeddedGenerator(
    purescript
  , defaultPsGeneratorOptions
  , PsGeneratorOptions(..)
  , PsModuleRoots(..)
) where

import Control.Monad (forM, when)
import Control.Monad.Writer (WriterT, runWriterT)
import Data.Default (def)
import Data.Maybe (catMaybes)
import Language.Haskell.TH.Syntax (Lift(..), liftString)
import System.Directory (createDirectory, removeDirectory)
import System.FilePath ((</>))
import System.FilePath.Glob (glob)
import System.IO (hPutStrLn, stderr)
import Yesod.EmbeddedStatic
import Yesod.EmbeddedStatic.Types

import qualified Language.PureScript as P
import qualified Language.PureScript.Bundle as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Map as M

-- | Specify PureScript modules for the roots for dead code eliminiation
data PsModuleRoots = AllSourceModules
                        -- ^ All modules located in the 'psSourceDirectory' will be used as roots
                   | SpecifiedModules [String]
                        -- ^ The specified module names will be used as roots

instance Lift PsModuleRoots where
    lift AllSourceModules = [| AllSourceModules |]
    lift (SpecifiedModules mods) = [| SpecifiedModules $(lift mods) |]

-- | The options to the generator.
data PsGeneratorOptions = PsGeneratorOptions {
    psSourceDirectory :: FilePath
        -- ^ The source directory containing PureScript modules.  All files recursively with a @purs@ extension
        -- will be loaded as PureScript code, and all files recursively with a @js@ extension will
        -- be loaded as foreign javascript.
  , psDependencySrcGlobs :: [String]
        -- ^ A list of globs (input to 'glob') for dependency PureScript modules.
  , psDependencyForeignGlobs :: [String]
        -- ^ A list of globs (input to 'glob') for dependency foreign javascript.
  , psDeadCodeElim :: PsModuleRoots
        -- ^ The module roots to use for dead code eliminiation.  All identifiers reachable from
        -- these modules will be kept.
  , psProductionMinimizer :: BL.ByteString -> IO BL.ByteString
        -- ^ Javascript minifier such as 'uglifyJs' to use when compiling for production.
        --   This is not used when compiling for development.
}

instance Lift PsGeneratorOptions where
    lift opts = [| PsGeneratorOptions $(liftString $ psSourceDirectory opts)
                                      $(lift $ psDependencySrcGlobs opts)
                                      $(lift $ psDependencyForeignGlobs opts)
                                      $(lift $ psDeadCodeElim opts)
                                      return
                |]

-- | Default options for the generator.
--
--   * All of the PureScript code and foreign JS you develop should go into a directory
--   @purescript@.
--
--   * The dependencies are loaded from @bower_components/purescript-*/src/@.  Thus if you list
--   all your dependencies in @bower.json@, this generator will automatically pick them all up.
--
--   * 'AllSourceModules' is used for dead code elimination, which means all modules located in the
--   @purescript@ directory are used as roots for dead code elimination.  That is, all code
--   reachable from a module from the @purescript@ directory is kept, and all other code from the
--   dependencies is thrown away.
--
--   * No production minimizer is configured.
defaultPsGeneratorOptions :: PsGeneratorOptions
defaultPsGeneratorOptions = PsGeneratorOptions
  { psSourceDirectory = "purescript"
  , psDependencySrcGlobs = ["bower_components/purescript-*/src/**/*.purs"]
  , psDependencyForeignGlobs = ["bower_components/purescript-*/src/**/*.js"]
  , psDeadCodeElim = AllSourceModules
  , psProductionMinimizer = return
  }

-- | Compile a PureScript project to a single javascript file.
--
-- When executing in development mode, the directory @.yesod-purescript@ is used to cache compiler
-- output. Every time a HTTP request for the given 'Location' occurs, the generator re-runs the
-- equivalent of @psc-make@. This recompiles any changed modules (detected by the file modification
-- time) and then bundles and serves the new javascript.  This allows you to change the PureScript
-- code or even add new PureScript modules, and a single refresh in the browser will recompile and
-- serve the new javascript without having to recompile/restart the Yesod server.
--
-- When compiling for production, the directory @.yesod-purescript@ is used for the compiler output
-- similar to development mode.  But instead of recompiling on every request, when compiling the
-- Haskell module which contains the call to 'purescript', the PureScript compiler will be executed
-- to compile all PureScript code and its dependencies.  The resulting javascript is then minimized,
-- compressed, and embdedded directly into the binary generated by GHC.  Thus you can distribute
-- your compiled Yesod server without having to distribute any PureScript code or its dependencies.
-- (This also means any changes to the PureScript code will require a re-compile of the Haskell
-- module containing the call to 'purescript').
--
-- All generated javascript code will be available under the global @PS@ variable. Thus from julius
-- inside a yesod handler, you can access exports from modules via something like
-- @[julius|PS.modulename.someexport("Hello, World")|]@.  There will not be any call to a main
-- function; you can call the main function yourself from julius inside your handler.
purescript :: Location -> PsGeneratorOptions -> Generator
purescript loc opts = do
    return [def
      { ebHaskellName = Just $ pathToName loc
      , ebLocation = loc
      , ebMimeType = "application/javascript"
      , ebProductionContent = compile loc opts ModeProduction >>= psProductionMinimizer opts
      , ebDevelReload = [| compile $(liftString loc) $(lift opts) ModeDevelopment |]
      }]

data MakeMode = ModeDevelopment | ModeProduction
    deriving (Show, Eq)

outputDir :: MakeMode -> FilePath
outputDir ModeDevelopment = ".yesod-purescript-build" </> "dev"
outputDir ModeProduction = ".yesod-purescript-build" </> "prod"

-- | Helper function to parse the purescript modules
parse :: [(FilePath, String)] -> [(FilePath, String)]
      -> WriterT P.MultipleErrors (Either P.MultipleErrors) ([(Either P.RebuildPolicy FilePath, P.Module)], M.Map P.ModuleName (FilePath, P.ForeignJS))
parse files foreign =
    (,) <$> P.parseModulesFromFiles (either (const "") id) (map (\(fp,str) -> (Right fp, str)) files)
        <*> P.parseForeignModulesFromFiles foreign

-- | Compile and bundle the purescript
compile :: Location -> PsGeneratorOptions -> MakeMode -> IO BL.ByteString
compile loc opts mode = do
    hPutStrLn stderr $ "Compiling " ++ loc

    srcNames <- glob (psSourceDirectory opts </> "**/*.purs")
    depNames <- concat <$> mapM glob (psDependencySrcGlobs opts)
    foreignNames <- concat <$> mapM glob
        ((psSourceDirectory opts </> "**/*.js") : psDependencyForeignGlobs opts)
    psFiles <- mapM (\f -> (f,) <$> readFile f) $ srcNames ++ depNames
    foreignFiles <- mapM (\f -> (f,) <$> readFile f) foreignNames

    case runWriterT (parse psFiles foreignFiles) of
        Left err -> do
            hPutStrLn stderr $ P.prettyPrintMultipleErrors False err
            case mode of
                ModeProduction -> error "Error parsing purescript"
                ModeDevelopment -> return $ TL.encodeUtf8 $ TL.pack $ P.prettyPrintMultipleErrors False err
        Right ((ms, foreigns), warnings) -> do
            when (P.nonEmpty warnings) $
                hPutStrLn stderr $ P.prettyPrintMultipleWarnings False warnings

            when (mode == ModeProduction) $ do
                removeDirectory $ outputDir mode
                createDirectory $ outputDir mode

            let filePathMap = M.fromList $ map (\(fp, P.Module _ mn _ _) -> (mn, fp)) ms
                psModuleNames = map (\(_, P.Module _ mn _ _) -> mn) ms

                checkSrcMod (Left _, _) = Nothing
                checkSrcMod (Right fp, P.Module _ mn _ _)
                    | fp `elem` srcNames = Just mn
                    | otherwise = Nothing
                srcModuleNames = catMaybes $ map checkSrcMod ms

                actions = P.buildMakeActions (outputDir mode) filePathMap foreigns False
                compileOpts = case mode of
                                ModeProduction -> P.defaultOptions
                                ModeDevelopment -> P.defaultOptions
                                                    { P.optionsNoOptimizations = True
                                                    , P.optionsVerboseErrors = True
                                                    }
            e <- P.runMake compileOpts $ P.make actions ms
            case e of
                Left err -> do
                    hPutStrLn stderr $ P.prettyPrintMultipleErrors False err
                    case mode of
                        ModeProduction -> error "Error compiling purescript"
                        ModeDevelopment -> return $ TL.encodeUtf8 $ TL.pack $ P.prettyPrintMultipleErrors False err
                Right (_, warnings') -> do
                    when (P.nonEmpty warnings') $
                        hPutStrLn stderr $ P.prettyPrintMultipleWarnings False warnings'
                    bundle opts mode psModuleNames srcModuleNames foreigns

-- | Bundle the generated javascript
bundle :: PsGeneratorOptions -> MakeMode -> [P.ModuleName] -> [P.ModuleName] -> M.Map P.ModuleName (FilePath, P.ForeignJS) -> IO BL.ByteString
bundle opts mode psModNames srcModNames foreigns = do
    let roots = case psDeadCodeElim opts of
                    AllSourceModules -> [ B.ModuleIdentifier (P.runModuleName mn) B.Regular | mn <- srcModNames]
                    SpecifiedModules mods -> [ B.ModuleIdentifier mn B.Regular | mn <- mods]

    indexJs <- forM psModNames $ \mn -> do
        idx <- readFile $ outputDir mode </> P.runModuleName mn </> "index.js"
        return (B.ModuleIdentifier (P.runModuleName mn) B.Regular, idx)
    let foreign = [(B.ModuleIdentifier (P.runModuleName mn) B.Foreign, js) | (mn, (_, js)) <- M.toList foreigns ]
    
    case B.bundle (indexJs ++ foreign) roots Nothing "PS" of
        Right r -> return $ TL.encodeUtf8 $ TL.pack r
        Left err -> do
            hPutStrLn stderr $ unlines $ B.printErrorMessage err
            case mode of
                ModeProduction -> error "Error bundling purescript"
                ModeDevelopment -> return $ TL.encodeUtf8 $ TL.pack $ unlines $ B.printErrorMessage err
