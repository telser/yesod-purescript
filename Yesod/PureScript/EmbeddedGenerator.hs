{-# LANGUAGE QuasiQuotes, TemplateHaskell, DataKinds, OverloadedStrings #-}
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
  , purescript'
  , purescriptPrelude
) where

import Control.Monad (forM)
import Control.Monad.Reader (runReaderT)
import Data.Default (def)
import Language.Haskell.TH (Q)
import Language.Haskell.TH.Syntax (lift, liftString, TExp, unTypeQ, unsafeTExpCoerce)
import System.Directory (doesDirectoryExist, getDirectoryContents)
import System.FilePath ((</>), takeExtension)
import System.IO (hPutStrLn, stderr)
import Yesod.EmbeddedStatic
import Yesod.EmbeddedStatic.Types

import qualified Language.PureScript as P
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL

-- | Compile a collection of purescript modules (along with the prelude) to a single javascript
-- file.
--
-- All generated javascript code will be available under the global @PS@ variable. Thus from julius
-- inside a yesod handler, you can access exports from modules via something like
-- @[julius|PS.modulename.someexport("Hello, World")|]@.  There will not be any call to a main function; you can
-- either call the main function yourself from julius inside your handler or use
-- the generator below to set 'P.optionsMain'. 
purescript :: Location
                -- ^ Location at which the generated javascript should appear inside the static subsite
           -> (BL.ByteString -> IO BL.ByteString)
                -- ^ Javascript minifier such as 'uglifyJs' to use when compiling for production.
                --   This is not used when compiling for development.
           -> [String]
                -- ^ List of purescript module names to use as roots for dead code elimination.
                --
                -- If the empty list is given, no dead code elimination is performed and all code will
                -- appear in the generated javascript.  If instead a list of modules is given, the purescript
                -- compiler will remove any code not reachable from these modules.  This is
                -- primarily useful to remove unused code from dependencies and the prelude.
           -> [FilePath]
                -- ^ Directories containing purescript code.  All files with a .purs extension located
                -- recursively in these directories will be given to the purescript compiler.  These paths
                -- are relative to the directory containing the cabal file.
           -> Generator
purescript loc mini roots = purescript' loc prodOpts devOpts mini
    where
        prodOpts = P.defaultCompileOptions
                    { P.optionsAdditional = P.CompileOptions "PS" roots []
                    }
        devOpts = [|| P.defaultCompileOptions
                        { P.optionsNoOptimizations = True
                        , P.optionsVerboseErrors = True
                        , P.optionsAdditional = P.CompileOptions "PS" $$(unsafeTExpCoerce $ lift roots) []
                        }
                  ||]

-- | A purescript generator which allows you to control the options given to the
-- purescript compiler for both production and development.
purescript' :: Location -- ^ Location at which the generated javascript should appear inside the static subsite
            -> P.Options 'P.Compile -- ^ options for compiling during production
            -> Q (TExp (P.Options 'P.Compile))
                -- ^ Template haskell splice for development options.  To create a value of this
                -- type, use @[|| ||]@ around a value of type @'P.Options' 'P.Compile'@. For example,
                --   @[|| defaultOptions { optionsNoOptimizations = True } ||]@
            -> (BL.ByteString -> IO BL.ByteString)
                -- ^ Javascript minifier such as 'uglifyJs' to use when compiling for production.
                -- This is not used when compiling for development.
            -> [FilePath]
                -- ^ Directories containing purescript code.  All files with a .purs extension located
                -- recursively in these directories will be given to the purescript compiler.  These paths
                -- are relative to the directory containing the cabal file.
            -> Generator
purescript' loc prodOpts devOpts mini dirs = do
    return [def
      { ebHaskellName = Just $ pathToName loc
      , ebLocation = loc
      , ebMimeType = "application/javascript"
      , ebProductionContent = compile loc prodOpts dirs >>= mini
      , ebDevelReload = [| compile $(liftString loc) $(unTypeQ devOpts) $(lift dirs) |]
      }]

-- | Embed the purescript 'P.prelude' into the static subsite.
--
-- The prelude only needs to appear once, so this is needed only if you specify 'P.optionsNoPrelude'
-- to the above generator, since by default the prelude is included.
purescriptPrelude :: Location -- location at which the prelude should appear
                  -> (BL.ByteString -> IO BL.ByteString)
                    -- ^ Javascript minifier such as 'uglifyJs' to use when compiling for production.
                    -- This is not used when compiling for development.
                  -> Generator
purescriptPrelude loc mini =
    return [def
        { ebHaskellName = Just $ pathToName loc
        , ebLocation = loc
        , ebMimeType = "application/javascript"
        , ebProductionContent = compile loc P.defaultCompileOptions [] >>= mini
        , ebDevelReload = [| compile $(liftString loc) P.defaultCompileOptions [] |]
        }]

-- | Helper function to compile a list of directories of purescript code.
compile :: Location -> P.Options 'P.Compile -> [FilePath] -> IO BL.ByteString
compile loc opts dirs = do
    hPutStrLn stderr $ "Compiling " ++ loc
    files <- concat <$> mapM getRecursiveContents dirs
    let modules = P.parseModulesFromFiles id $
            if P.optionsNoPrelude opts
                then files
                else ("<prelude>", P.prelude) : files
    case modules of
        Left err -> do
            hPutStrLn stderr $ show err
            return $ TL.encodeUtf8 $ TL.pack $ show err
        Right ms -> do
            case P.compile (map snd ms) ["yesod-purescript"] `runReaderT` opts of
                Left err -> do
                    hPutStrLn stderr err
                    return $ TL.encodeUtf8 $ TL.pack err
                Right (js, _, _) -> return $ TL.encodeUtf8 $ TL.pack js

-- | Get contents of all .purs files recursively in a directory
getRecursiveContents :: FilePath -> IO [(FilePath, String)]
getRecursiveContents topdir = do
  names <- getDirectoryContents topdir
  let properNames = filter (`notElem` [".", ".."]) names
  paths <- forM properNames $ \name -> do
    let path = topdir </> name
    isDirectory <- doesDirectoryExist path
    case (isDirectory, takeExtension path) of
        (True, _) -> getRecursiveContents path
        (False, ".purs") -> do
              ct <- readFile path
              return [(path, ct)]
        _ -> return []
  return (concat paths)
