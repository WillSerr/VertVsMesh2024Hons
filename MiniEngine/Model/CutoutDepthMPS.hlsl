
#include "MeshCommon.hlsli"

struct VSOutput
{
    float4 pos : SV_Position;
    float2 uv : TexCoord0;
};

Texture2D<float4> baseColorTexture : register(t0);
SamplerState baseColorSampler : register(s0);

cbuffer MaterialConstants : register(b0)
{
    float4 baseColorFactor;
    float3 emissiveFactor;
    float normalTextureScale;
    float2 metallicRoughnessFactor;
    uint flags;
}


[RootSignature(Mesh_Renderer_RootSig)]
void main(VSOutput vsOutput)
{
    float cutoff = f16tof32(flags >> 16);
    clamp(vsOutput.uv.x, 0, 1);
    clamp(vsOutput.uv.y, 0, 1);
    //if (baseColorTexture.Sample(baseColorSampler, vsOutput.uv).a < cutoff)
    //    discard;
}
