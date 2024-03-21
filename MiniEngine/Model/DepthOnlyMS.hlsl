
#include "MeshCommon.hlsli"

#ifdef ENABLE_SKINNING
//#undef ENABLE_SKINNING
#endif

struct MeshConstants
{
    float4x4 WorldMatrix; // Object to world
    float3x3 WorldIT; // Object normal to world normal
};

struct GlobalConstants
{
    float4x4 ViewProjMatrix;
    float4x4 SunShadowMatrix;
    float3 ViewerPos;
    float3 SunDirection;
    float3 SunIntensity;
};

#ifdef ENABLE_SKINNING
struct Joint
{
    float4x4 PosMatrix;
    float4x3 NrmMatrix; // Inverse-transpose of PosMatrix
};

StructuredBuffer<Joint> Joints : register(t20);
#endif

struct Vertex
{
    float3 position;    
#ifdef ENABLE_ALPHATEST
    uint uv0;  //Due to there being no IA, the 2 16bit floats are passed as one 32bit value
#endif
#ifdef ENABLE_SKINNING
    uint4 jointIndices : BLENDINDICES;
    float4 jointWeights : BLENDWEIGHT;
#endif
};

struct VSOutput
{
    float4 position : SV_POSITION;
#ifdef ENABLE_ALPHATEST
    float2 uv0 : TEXCOORD0;
#endif
};


ConstantBuffer<MeshConstants> Constants : register(b0);
ConstantBuffer<GlobalConstants> Globals : register(b1);

StructuredBuffer<Vertex> Vertices : register(t21);
StructuredBuffer<Meshlet> Meshlets : register(t22);

float Convert16To32BitFloat(uint SmallFloat)
{
    
    uint signs = (SmallFloat & 0xc000) << 16;
    uint value = (SmallFloat & 0x3fff) << 13;
    
    //Signs, Padding, exponent, mantissa
    uint finalFloat = signs | ((((SmallFloat >> 14) & 0x1) ^ 0x1) * 0x38000000) | value;
    
    return asfloat(finalFloat);
}

float2 ReadUVs(uint packedUV)
{
    float2 texcoord = float2(1, 1);
    uint floatValue = 0;  
    
    //floatValue = packedUV & 0xFFFF;
    //texcoord.x = Convert16To32BitFloat(floatValue);
    texcoord.x = f16tof32(packedUV);

    
    //floatValue = (packedUV >> 16) & 0xFFFF;
    //texcoord.y = Convert16To32BitFloat(floatValue);
    texcoord.y = f16tof32(packedUV>>16);
    
    return texcoord;
}

VSOutput GetVertexAttributes(uint meshletIndex, uint vertexIndex)
{
    Vertex v = Vertices[vertexIndex];
    VSOutput vout;
    
    float4 position = float4(v.position, 1.0);

#ifdef ENABLE_SKINNING
    // I don't like this hack.  The weights should be normalized already, but something is fishy.
    float4 weights = v.jointWeights / dot(v.jointWeights, 1);

    float4x4 skinPosMat =
        Joints[v.jointIndices.x].PosMatrix * weights.x +
        Joints[v.jointIndices.y].PosMatrix * weights.y +
        Joints[v.jointIndices.z].PosMatrix * weights.z +
        Joints[v.jointIndices.w].PosMatrix * weights.w;

    position = mul(skinPosMat, position);

#endif

    float3 worldPos = mul(Constants.WorldMatrix, position).xyz;
    vout.position = mul(Globals.ViewProjMatrix, float4(worldPos, 1.0));

#ifdef ENABLE_ALPHATEST
    //vout.uv0 = v.uv0;
    
    vout.uv0 = ReadUVs(v.uv0);
#endif
    
    return vout;
}

[RootSignature(Mesh_Renderer_RootSig)]
[NumThreads(128, 1, 1)]
[OutputTopology("triangle")]
void main(
    uint gtid : SV_GroupThreadID,
    uint gid : SV_GroupID,
    out indices uint3 tris[126],
    out vertices VSOutput verts[64]
)
{
    Meshlet m = Meshlets[MeshInfo.MeshletOffset + gid];

    SetMeshOutputCounts(m.VertCount, m.PrimCount);
    
    //bool wrotePrim = false;
    
    if (gtid < m.PrimCount)
    {
        //uint3 vals = GetPrimitive(m, gtid);
        tris[gtid] = GetPrimitive(m, gtid);
        //tris[gtid] = uint3(0, 1, 2);
        //wrotePrim = true;
    }

    if (gtid < m.VertCount)
    {
        //VSOutput vs;
        //if (gtid < m.PrimCount)
        //{        
        //    vs.position = float4(GetPrimitive(m, gtid), 1);
        //    verts[gtid] = vs;
        //}
        //else
        //{
            uint vertexIndex = GetVertexIndex(m, gtid);
            verts[gtid] = GetVertexAttributes(gid, vertexIndex);
        //}
        //vs.position = float4(1, -1, 0.2, 1);

        //vs = GetVertexAttributes(gid, vertexIndex);
        //vs.position.z = gid;
        //vs.position.w = m.PrimCount;
        //if (gtid % 3 == 1)
        //{
        //    vs.position = float4(-1, -1, 0.2, 1);
        //}
        //if (gtid % 3 == 2)
        //{
        //    vs.position = float4(-1, 1, 0.2, 1);
        //}
        //#ifdef ENABLE_ALPHATEST
        //            //Vertex v = Vertices[vertexIndex];
        //            //vs.uv0 = ReadUVs(v.uv0);
        //            vs.uv0.x = wrotePrim;
        //            vs.uv0.y = gtid;
        //#endif
        
        
        //verts[gtid] = vs;

    }
}