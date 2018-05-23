{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module Main where

import           Control.Monad          (forM_)
import           Control.Monad.Except   (MonadError (..), runExceptT)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Function          (fix)
import           Data.List              (nub)
import           Data.String            (fromString)
import           Foreign.C.String
import           Foreign.Marshal.Array
import           Foreign.Marshal.Utils
import           Foreign.Ptr
import           Foreign.Storable
import           Graphics.GL.Core33
import           Graphics.GL.Types
import           SDL

import           Gristle
import           Gristle.Syntax


-- TODO: More complicated shaders.
-- Write some shaders that do a lot of things.


passthruVert
  :: Value (In (Vec 2 Float))
  -> GLSL Vertex ()
passthruVert pos = do
  let (x, y) = decomp $ readFrom pos
  set glPosition $ vec4 x y 0 1


passthruFrag
  :: Value (Uniform Float)
  -> GLSL Fragment ()
passthruFrag utime = do
  let r = abs $ sin $ readFrom utime
  set glFragColor $ vec4 r 0 0 1


-- | Creates and returns an SDL2 window.
initSDL2Window
  :: MonadIO m
  => WindowConfig
  -- ^ The window configuration
  -> String
  -- ^ The window title.
  -> m Window
initSDL2Window cfg title = liftIO $ do
  initializeAll
  w <- createWindow (fromString title) cfg
  _ <- glCreateContext w
  return w


 --------------------------------------------------------------------------------
-- OpenGL shader only stuff
--------------------------------------------------------------------------------
compileOGLShader
  :: (MonadIO m, MonadError String m)
  => String
  -- ^ The shader source
  -> GLenum
  -- ^ The shader type (vertex, frag, etc)
  -> m GLuint
  -- ^ Either an error message or the generated shader handle.
compileOGLShader src shType = do
  shdr <- liftIO $ glCreateShader shType
  if shdr == 0
    then throwError "Could not create shdr"
    else do
      success <- liftIO $ do
        withCString src $ \ptr ->
          with ptr $ \ptrptr -> glShaderSource shdr 1 ptrptr nullPtr

        glCompileShader shdr
        with (0 :: GLint) $ \ptr -> do
          glGetShaderiv shdr GL_COMPILE_STATUS ptr
          peek ptr

      if success == GL_FALSE
        then do
          err <- liftIO $ do
            infoLog <- with (0 :: GLint) $ \ptr -> do
                glGetShaderiv shdr GL_INFO_LOG_LENGTH ptr
                logsize <- peek ptr
                allocaArray (fromIntegral logsize) $ \logptr -> do
                    glGetShaderInfoLog shdr logsize nullPtr logptr
                    peekArray (fromIntegral logsize) logptr

            return $ unlines [ "Could not compile shdr:"
                             , src
                             , map (toEnum . fromEnum) infoLog
                             ]
          throwError err
        else return shdr


compileShader
  :: (MonadIO m, MonadError String m, Shader t)
  => t
  -> m ([String], GLuint)
compileShader t = do
  let link = linkages t
  ctx <- case shaderLinkageCtx link of
    "vertex"   -> return GL_VERTEX_SHADER
    "fragment" -> return GL_FRAGMENT_SHADER
    ctx        -> throwError $ unwords [ "Shader context"
                                       , ctx
                                       , "is not yet supported"
                                       ]
  sh <- compileOGLShader (shaderLinkageSrc link) ctx
  return (map valueToName $ shaderLinkageAttribs link, sh)


compileOGLProgram
  :: (MonadIO m, MonadError String m)
  => [(String, Integer)]
  -> [GLuint]
  -> m GLuint
compileOGLProgram attribs shaders = do
  (program, success) <- liftIO $ do
    program <- glCreateProgram
    forM_ shaders (glAttachShader program)
    forM_ attribs $ \(name, loc) ->
        withCString name $ glBindAttribLocation program $ fromIntegral loc
    glLinkProgram program

    success <- with (0 :: GLint) $ \ptr -> do
        glGetProgramiv program GL_LINK_STATUS ptr
        peek ptr
    return (program, success)

  if success == GL_FALSE
    then do
      err <- liftIO $ with (0 :: GLint) $ \ptr -> do
        glGetProgramiv program GL_INFO_LOG_LENGTH ptr
        logsize <- peek ptr
        infoLog <- allocaArray (fromIntegral logsize) $ \logptr -> do
          glGetProgramInfoLog program logsize nullPtr logptr
          peekArray (fromIntegral logsize) logptr
        return $ unlines [ "Could not link program"
                          , map (toEnum . fromEnum) infoLog
                          ]
      throwError err
    else do
      liftIO $ forM_ shaders glDeleteShader
      return program


compileProgram
  :: (MonadIO m, MonadError String m)
  => [([String], GLuint)]
  -> m GLuint
compileProgram params = do
  let (atts, shs) = unzip params
      natts = nub $ concat atts
  compileOGLProgram (zip natts [0..]) shs


main :: IO ()
main = do
  let openGL = defaultOpenGL{ glProfile = Core Debug 3 3 }
      cfg = defaultWindow{ windowOpenGL = Just openGL
                         , windowResizable = True
                         }

  w <- initSDL2Window cfg "gristle example"
  eErrOrPgm <-
    runExceptT $ compileProgram =<< sequence [ compileShader passthruVert
                                             , compileShader passthruFrag
                                             ]


  case eErrOrPgm of
    Left err      -> do
      putStrLn "Got error from shaders:"
      print $ linkages passthruVert
      print $ linkages passthruFrag
      putStrLn err

    Right program -> do
      glUseProgram program
      fix $ \loop -> do
        _ <- pollEvents
        glSwapWindow w
        loop
