#pragma once

#include "Camera.h"
#include "CommandContext.h"
#include "TemporalEffects.h"
#include "MotionBlur.h"
#include "DepthOfField.h"
#include "PostEffects.h"
#include "SSAO.h"
#include "FXAA.h"
#include "SystemTime.h"

#include "Renderer.h"

#include "glTF.h"
#include "Display.h"
#include "ModelLoader.h"

extern ExpVar g_SunLightIntensity;
extern NumVar g_SunOrientation;
extern NumVar g_SunInclination;

void ChangeIBLSet(EngineVar::ActionType);
void ChangeIBLBias(EngineVar::ActionType);

extern DynamicEnumVar g_IBLSet;
extern std::vector<std::pair<TextureRef, TextureRef>> g_IBLTextures;
extern NumVar g_IBLBias;

void ChangeIBLSet(EngineVar::ActionType);
void ChangeIBLBias(EngineVar::ActionType);
void LoadIBLTextures();