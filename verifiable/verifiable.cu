#pragma nv_diag_suppress declared_but_not_referenced

#include "verifiable.h"
#include <nccl.h>

#include <cuda_runtime.h>
#include <cuda_fp16.h>
#if CUDART_VERSION >= 11000
#include <cuda_bf16.h>
#endif
#if CUDART_VERSION >= 11080
#include <cuda_fp8.h>
#endif

#if NCCL_VERSION_CODE >= NCCL_VERSION(2,24,0) && defined(__CUDA_FP8_TYPES_EXIST__)
  #define HAVE_ncclFloat8 1
#else
  #define HAVE_ncclFloat8 0
#endif

#if NCCL_VERSION_CODE >= NCCL_VERSION(2,10,0) && defined(__CUDA_BF16_TYPES_EXIST__)
  #define HAVE_ncclBfloat16 1
#else
  #define HAVE_ncclBfloat16 0
#endif

#if NCCL_VERSION_CODE >= NCCL_VERSION(2,10,0)
  #define HAVE_ncclAvg 1
#else
  #define HAVE_ncclAvg 0
#endif

#if NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0)
  #define HAVE_ncclPreMulSum 1
#else
  #define HAVE_ncclPreMulSum 0
#endif

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <unistd.h>

using std::size_t;
using std::int8_t;
using std::int16_t;
using std::int32_t;
using std::int64_t;
using std::uint8_t;
using std::uint16_t;
using std::uint32_t;
using std::uint64_t;

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T>
__device__ unsigned long long bitsOf(T x) {
  union { unsigned long long ull; T val; } u;
  u.ull = 0;
  u.val = x;
  return u.ull;
}

__host__ __device__ uint64_t mixBits(uint64_t x) {
  union { uint32_t u32[2]; uint64_t u64; };
  u64 = x;
  u32[1] += 1;
  u32[0] ^= u32[1];
  u64 *= 0x9e3779b97f4a7c13u;
  u32[0] ^= u32[1]<<16 ^ u32[1]>>16;
  return u64;
}

__host__ __device__ uint64_t hashOf(uint64_t a, uint64_t b=0) {
  a += uint64_t(1)<<32;
  a += b;
  a ^= a>>32;
  a *= 0x9e3779b97f4a7c13u;
  a += b>>16 ^ b<<48;
  a ^= a>>32;
  a *= 0xc4ceb9fe1a85ec53u;
  return a;
}
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T>
struct IsIntegral: std::is_integral<T> {};
template<>
struct IsIntegral<half>: std::false_type {};
#if HAVE_ncclBfloat16
template<>
struct IsIntegral<__nv_bfloat16>: std::false_type {};
#endif
#if HAVE_ncclFloat8
template<>
struct IsIntegral<__nv_fp8_e4m3>: std::false_type {};
template<>
struct IsIntegral<__nv_fp8_e5m2>: std::false_type {};
#endif
}

////////////////////////////////////////////////////////////////////////////////

// Hide a value from arithmetic optimizations. Hopefully compiler cannot detect
// that this is equivalent to the identity function.
template<typename T>
__host__ __device__ T inhibit(T x) {
  union { uint64_t u64; T val; };
  u64 = 0;
  val = x;
  u64 *= 0x0000000100000001u;
  u64 *= 0xffffffff00000001u;
  return val;
}

////////////////////////////////////////////////////////////////////////////////

namespace {
  template<typename Y>
  __host__ __device__ Y castTo(uint64_t x) {
    return Y(x);
  }
  template<typename Y>
  __host__ __device__ Y castTo(float x) {
    return Y(x);
  }
  template<typename Y>
  __host__ __device__ Y castTo(double x) {
    return Y(x);
  }

  template<>
  __host__ __device__ half castTo<half>(float x) {
    return __float2half(x);
  }
  template<>
  __host__ __device__ half castTo<half>(double x) {
    return __double2half(x);
  }
  template<>
  __host__ __device__ half castTo<half>(uint64_t x) {
    return __ull2half_rn(x);
  }

  #if HAVE_ncclBfloat16
  template<>
  __host__ __device__ __nv_bfloat16 castTo<__nv_bfloat16>(float x) {
    return __float2bfloat16(x);
  }
  template<>
  __host__ __device__ __nv_bfloat16 castTo<__nv_bfloat16>(double x) {
    return __double2bfloat16(x);
  }
  template<>
  __host__ __device__ __nv_bfloat16 castTo<__nv_bfloat16>(uint64_t x) {
    return __double2bfloat16((double)x);
  }
  #endif

  #if HAVE_ncclFloat8
  template<>
  __host__ __device__ __nv_fp8_e4m3 castTo<__nv_fp8_e4m3>(float x) {
    return __nv_fp8_e4m3(x);
  }
  template<>
  __host__ __device__ __nv_fp8_e4m3 castTo<__nv_fp8_e4m3>(double x) {
    return __nv_fp8_e4m3(x);
  }
  template<>
  __host__ __device__ __nv_fp8_e4m3 castTo<__nv_fp8_e4m3>(uint64_t x) {
    return __nv_fp8_e4m3((double)x);
  }
  template<>
  __host__ __device__ __nv_fp8_e5m2 castTo<__nv_fp8_e5m2>(float x) {
    return __nv_fp8_e5m2(x);
  }
  template<>
  __host__ __device__ __nv_fp8_e5m2 castTo<__nv_fp8_e5m2>(double x) {
    return __nv_fp8_e5m2(x);
  }
  template<>
  __host__ __device__ __nv_fp8_e5m2 castTo<__nv_fp8_e5m2>(uint64_t x) {
    return __nv_fp8_e5m2((double)x);
  }
  #endif
}

////////////////////////////////////////////////////////////////////////////////
// The reduction functions

namespace {
struct ReduceNil {
  template<typename T>
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  template<typename T>
  __host__ __device__ T operator()(T a, T /*b*/) const { return a; }
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};
struct ReduceSum {
  template<typename T>
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  template<typename T, typename=decltype(T()+T())>
  __host__ __device__ T operator()(T a, T b) const { return a + b; }
  __host__ __device__ half operator()(half a, half b) const {
    #if __CUDA_ARCH__ >= 530
      return __hadd(a, b);
    #else
      return __float2half(__half2float(a) + __half2float(b));
    #endif
  }
  #if HAVE_ncclBfloat16
  __host__ __device__ __nv_bfloat16 operator()(__nv_bfloat16 a, __nv_bfloat16 b) const {
    #if __CUDA_ARCH__ >= 800
      return __hadd(a, b);
    #else
      return __float2bfloat16(__bfloat162float(a) + __bfloat162float(b));
    #endif
  }
  #endif
  #if HAVE_ncclFloat8
  __host__ __device__ __nv_fp8_e4m3 operator()(__nv_fp8_e4m3 a, __nv_fp8_e4m3 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e4m3(__hadd(__half(a), __half(b)));
    #else
      return __nv_fp8_e4m3(float(a) + float(b));
    #endif
  }
  __host__ __device__ __nv_fp8_e5m2 operator()(__nv_fp8_e5m2 a, __nv_fp8_e5m2 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e5m2(__hadd(__half(a), __half(b)));
    #else
      return __nv_fp8_e5m2(float(a) + float(b));
    #endif
  }
  #endif
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};
struct ReduceProd {
  template<typename T>
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  template<typename T, typename=decltype(T()*T())>
  __host__ __device__ T operator()(T a, T b) const { return a * b; }
  __host__ __device__ half operator()(half a, half b) const {
    #if __CUDA_ARCH__ >= 530
      return __hmul(a, b);
    #else
      return __float2half(__half2float(a) * __half2float(b));
    #endif
  }
  #if HAVE_ncclBfloat16
  __host__ __device__ __nv_bfloat16 operator()(__nv_bfloat16 a, __nv_bfloat16 b) const {
    #if __CUDA_ARCH__ >= 800
      return __hmul(a, b);
    #else
      return __float2bfloat16(__bfloat162float(a) * __bfloat162float(b));
    #endif
  }
  #endif
  #if HAVE_ncclFloat8
  __host__ __device__ __nv_fp8_e4m3 operator()(__nv_fp8_e4m3 a, __nv_fp8_e4m3 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e4m3(__hmul(__half(a), __half(b)));
    #else
      return __nv_fp8_e4m3(float(a) * float(b));
    #endif
  }
  __host__ __device__ __nv_fp8_e5m2 operator()(__nv_fp8_e5m2 a, __nv_fp8_e5m2 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e5m2(__hmul(__half(a), __half(b)));
    #else
      return __nv_fp8_e5m2(float(a) * float(b));
    #endif
  }
  #endif
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};
struct ReduceMin {
  template<typename T>
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  template<typename T, typename=decltype(T()<T())>
  __host__ __device__ T operator()(T a, T b) const { return a < b ? a : b; }
  __host__ __device__ half operator()(half a, half b) const {
    #if __CUDA_ARCH__ >= 800
      return __hmin(a, b);
    #elif __CUDA_ARCH__ >= 530
      return __hlt(a, b) ? a : b;
    #else
      return __half2float(a) < __half2float(b) ? a : b;
    #endif
  }
  #if HAVE_ncclBfloat16
  __host__ __device__ __nv_bfloat16 operator()(__nv_bfloat16 a, __nv_bfloat16 b) const {
    #if __CUDA_ARCH__ >= 800
      return __hmin(a, b);
    //#elif __CUDA_ARCH__ >= 530
    //  return __hlt(a, b) ? a : b;
    #else
      return __bfloat162float(a) < __bfloat162float(b) ? a : b;
    #endif
  }
  #endif
  #if HAVE_ncclFloat8
  __host__ __device__ __nv_fp8_e4m3 operator()(__nv_fp8_e4m3 a, __nv_fp8_e4m3 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e4m3(__hmin(__half(a), __half(b)));
    #else
      return __nv_fp8_e4m3(float(a) < float(b) ? a : b);
    #endif
  }
  __host__ __device__ __nv_fp8_e5m2 operator()(__nv_fp8_e5m2 a, __nv_fp8_e5m2 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e5m2(__hmin(__half(a), __half(b)));
    #else
      return __nv_fp8_e5m2(float(a) < float(b) ? a : b);
    #endif
  }
  #endif
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};
struct ReduceMax {
  template<typename T>
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  template<typename T, typename=decltype(T()>T())>
  __host__ __device__ T operator()(T a, T b) const { return a > b ? a : b; }
  __host__ __device__ half operator()(half a, half b) const {
    #if __CUDA_ARCH__ >= 800
      return __hmax(a, b);
    #elif __CUDA_ARCH__ >= 530
      return __hgt(a, b) ? a : b;
    #else
      return __half2float(a) > __half2float(b) ? a : b;
    #endif
  }
  #if HAVE_ncclBfloat16
  __host__ __device__ __nv_bfloat16 operator()(__nv_bfloat16 a, __nv_bfloat16 b) const {
    #if __CUDA_ARCH__ >= 800
      return __hmax(a, b);
    //#elif __CUDA_ARCH__ >= 530
    //  return __hgt(a, b) ? a : b;
    #else
      return __bfloat162float(a) > __bfloat162float(b) ? a : b;
    #endif
  }
  #endif
  #if HAVE_ncclFloat8
  __host__ __device__ __nv_fp8_e4m3 operator()(__nv_fp8_e4m3 a, __nv_fp8_e4m3 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e4m3(__hmax(__half(a), __half(b)));
    #else
      return __nv_fp8_e4m3(float(a) > float(b) ? a : b);
    #endif
  }
  __host__ __device__ __nv_fp8_e5m2 operator()(__nv_fp8_e5m2 a, __nv_fp8_e5m2 b) const {
    #if __CUDA_ARCH__ >= 800
      return __nv_fp8_e5m2(__hmax(__half(a), __half(b)));
    #else
      return __nv_fp8_e5m2(float(a) > float(b) ? a : b);
    #endif
  }
  #endif
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};
struct ReducePreMulSum {
  template<typename T>
  __host__ __device__ T preOp(T x, int rank_me) const {
    return ReduceProd()(x, ncclVerifiablePremulScalar<T>(rank_me));
  }
  template<typename T>
  __host__ __device__ T operator()(T a, T b) const { return ReduceSum()(a, b); }
  template<typename T>
  __host__ __device__ T postOp(T x) const { return x; }
};

template<typename T, bool integral = IsIntegral<T>::value>
struct ReduceAvg_Base;

template<typename T>
struct ReduceAvg_Base<T, /*integral=*/true> {
  int rank_n;
  __host__ __device__ T preOp(T x, int /*rank_me*/) const { return x; }
  __host__ __device__ T operator()(T a, T b) const { return ReduceSum()(a, b); }
  __host__ __device__ T postOp(T x) const { return x/rank_n; }
};

template<typename T>
struct ReduceAvg_Base<T, /*integral=*/false> {
  int rank_n;
  __host__ __device__ T preOp(T x, int /*rank_me*/) const {
    using T1 = typename std::conditional<(sizeof(T)<sizeof(double)), float, double>::type;
    return ReduceProd()(inhibit(castTo<T>(T1(1)/T1(rank_n))), inhibit(x));
  }
  __host__ __device__ T operator()(T a, T b) const { return ReduceSum()(a, b); }
  __host__ __device__ T postOp(T x) const { return x; }
};

struct ReduceAvg {
  int rank_n;
  template<typename T>
  __host__ __device__ T preOp(T x, int rank_me) const {
    return ReduceAvg_Base<T>{rank_n}.preOp(x, rank_me);
  }
  template<typename T>
  __host__ __device__ T operator()(T a, T b) const {
    return ReduceAvg_Base<T>{rank_n}(a, b);
  }
  template<typename T>
  __host__ __device__ T postOp(T x) const {
    return ReduceAvg_Base<T>{rank_n}.postOp(x);
  }
};
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T>
struct FloatLayout { static constexpr bool is_floating_point = false; };
template<>
struct FloatLayout<float> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 8, mantissa_bits = 23;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
template<>
struct FloatLayout<double> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 11, mantissa_bits = 52;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
template<>
struct FloatLayout<half> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 5, mantissa_bits = 10;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
#if HAVE_ncclBfloat16
template<>
struct FloatLayout<__nv_bfloat16> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 8, mantissa_bits = 7;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
#endif
#if HAVE_ncclFloat8
template<>
struct FloatLayout<__nv_fp8_e4m3> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 4, mantissa_bits = 3;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
template<>
struct FloatLayout<__nv_fp8_e5m2> {
  static constexpr bool is_floating_point = true;
  static constexpr int exponent_bits = 5, mantissa_bits = 2;
  static constexpr int exponent_bias = (1<<(exponent_bits-1))-1;
};
#endif

template<typename T>
__host__ __device__ T makeFloat(int sign, int exp, uint64_t mant) {
  union { T ans; uint64_t bits; };
  bits = sign;
  bits <<= FloatLayout<T>::exponent_bits;
  bits |= exp;
  bits <<= FloatLayout<T>::mantissa_bits;
  bits |= mant;
  return ans;
}
}

////////////////////////////////////////////////////////////////////////////////

namespace {
// High bits of multiplcation are useful for generating bounded random values
// from unbounded random values. For instance, given X a totally random 32-bit
// integer, `umul32hi(X,n)` will be totally random within [0,n).
__host__ __device__ uint64_t umul32hi(uint32_t a, uint32_t b) {
#ifdef __CUDA_ARCH__
  return __umulhi(a, b);
#else
  return uint64_t(a)*b >> 32;
#endif
}
__host__ __device__ uint64_t umul64hi(uint64_t a, uint64_t b) {
#ifdef __CUDA_ARCH__
  return __umul64hi(a, b);
#else
  return uint64_t(__uint128_t(a)*__uint128_t(b) >> 64);
#endif
}

__host__ __device__ int clz32(int x) {
#ifdef __CUDA_ARCH__
  return __clz(x);
#else
  return x==0 ? 32 : __builtin_clz(x);
#endif
}
__host__ __device__ int clz64(long long x) {
#ifdef __CUDA_ARCH__
  return __clzll(x);
#else
  return x==0 ? 64 : __builtin_clzll(x);
#endif
}
}

////////////////////////////////////////////////////////////////////////////////

namespace {
// Returns a wildly permuted rank index. Useful when we know we want exactly N
// random ranks to exhibit some behavior, we can just test if:
// `shuffleRank(rank_n, rank_me, rng) < N`. Note that rank_n > 0 must be true
// for well defined results. This mixes the bits of rng.
__host__ __device__ int shuffleRank(int rank_n, int rank_me, uint64_t &rng) {
  uint32_t a = uint32_t(rng);
  uint32_t b = uint32_t(rng>>32);
  rng = mixBits(rng);

  uint32_t r = rank_me;
  // round down rank_n to largest pow2, then subtract 1
  uint32_t n2 = (~uint32_t(0)>>1) >> clz32(rank_n);

  // These are 1:1 functions modulo 2^n:
  //   f(x) = x*a + b : for odd a, any b
  //   f(x) = (x*x + x)/2
  // So we apply both to the bottom n2+1 ranks, then rotate the top
  // (rank_n-n2-1) to the bottom and apply both again.

  if(r <= n2) {
    // shuffle bottom n2+1 ranks
    r = (r*(a|1) + b) & n2;
    r = (r*r + r)/2 & n2;
    // rotate top to bottom
    r += rank_n - (n2+1);
  }
  else
    r -= n2+1; // rotate top to bottom

  if(r <= n2) {
    // shuffle bottom n2+1 again
    r = (r*(b|1) + a) & n2;
    r = (r*r + r)/2 & n2;
  }
  return r;
}
}

namespace {
// Generate wild integers x and y such that if every rank submits its x into a
// summation the result will be y with y <= y_max. Ranks should be shuffled
// before calling.
template<typename Uint>
__host__ __device__ void genSumXY(
    int rank_n, int rank_me, uint64_t &rng, Uint y_max, Uint &x, Uint &y,
    bool avoid_y=false // if true then returned y will not equal given y
  ) {
  static_assert(std::is_unsigned<Uint>::value, "Type must be unsigned integral.");

  { // Pick y as a random value in [y_max/2, y_max]
    Uint d, y_min = (y_max+1)/2;
    if(8*sizeof(Uint) > 32)
      d = umul64hi(rng, y_max/2 + (avoid_y ? 0 : 1));
    else
      d = umul32hi(uint32_t(rng), y_max/2 + (avoid_y ? 0 : 1));
    Uint y1 = (avoid_y ? y+1 : y_min) + d;
    y = y1 - (avoid_y && (y1 < y_min || y_max < y1) ? y_max/2 : 0);
  }
  rng = mixBits(rng);

  unsigned r = unsigned(rank_me);
  unsigned rn = unsigned(rank_n);
  // Partition our rn ranks into pn distinct subsets each of size rn/pn. If each
  // rank submits 1+p (where p is 0-based partition index) then the sum be:
  //   (rn/pn) * pn*(pn+1)/2
  // So set this equal to our desired sum y and solve for pn.
  //   (rn/pn) * pn*(pn+1)/2 = y
  //   rn*(pn+1)/2 = y
  //   pn = 2*(y/rn)-1
  Uint pn = rn == 1 ? 1 : 2*(y/rn) - 1;
  // In the case where rn is huge (compared to y) use only one partition meaning
  // that all rn ranks will submit 1 (since p=0).
  pn = pn == 0 ? 1 : pn;
  // Can't have more partitions than ranks.
  pn = rn < pn ? rn : pn;
  // Compute sum of contribution from pn partitions where each submits p+1.
  Uint p_sum;
  if(y_max <= ~uint32_t(0)>>1) // compile time known
    p_sum = Uint(uint32_t(pn)*uint32_t(pn+1)/2);
  else
    p_sum = Uint(uint64_t(pn)*uint64_t(pn+1)/2);
  // Let s be the number of ranks per partition. This is either rn/pn as we
  // intended, or y/p_sum if that's smaller to prevent overshooting our target y.
  uint32_t s = y/p_sum < rn/pn ? y/p_sum : rn/pn;
  x = r/s < pn ? 1 + r/s : 0; //  First s*pn ranks contribute partition index +1.
  x += r == rn-1 ? y - s*p_sum : 0; // Last rank contributes discrepancy.
}
}

namespace {
template<typename T>
__host__ __device__ T genInOutFloatSum(
    bool input_not_output, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    bool same_sign
  ) {
  constexpr int exp_lo = 1 + FloatLayout<T>::mantissa_bits;
  constexpr int exp_hi = (1<<FloatLayout<T>::exponent_bits)-1;
  using uintmant_t = typename std::conditional<(8*sizeof(T) > 32), uint64_t, uint32_t>::type;
  constexpr uintmant_t mant_mask = (uintmant_t(1) << FloatLayout<T>::mantissa_bits)-1;
  constexpr uintmant_t max_mant = 2*mant_mask + 1; // add implicit leading 1
  uint64_t rng = hashOf(seed, index);

  int y_sign = rng & 1;
  int x_sign = y_sign;
  int xy_exp = exp_lo + umul32hi(uint32_t(rng>>32), exp_hi-exp_lo);
  rng = mixBits(rng);
  rank_me = shuffleRank(rank_n, rank_me, rng);

  // If we're using mixed signs then partition into evens and odds.
  int subrank_n = same_sign ? rank_n : (rank_n+1)/2;
  int subrank_me = same_sign ? rank_me : rank_me/2;
  uintmant_t x0_mant, y0_mant;
  genSumXY(subrank_n, subrank_me, rng, max_mant, x0_mant, y0_mant);

  if (!same_sign && (rank_n+0)/2 != 0) {
    uintmant_t x1_mant, y1_mant = y0_mant;
    // Avoid generating y1_mant == y0_mant so we don't have to worry about
    // signed zero as the result.
    genSumXY((rank_n+0)/2, rank_me/2, rng, max_mant, x1_mant, y1_mant, /*avoid_y=*/true);
    y_sign ^= y0_mant < y1_mant ? 1 : 0;
    y0_mant = (y0_mant < y1_mant ? -1 : 1)*(y0_mant - y1_mant);
    x_sign ^= rank_me%2;
    x0_mant = rank_me%2 == 0 ? x0_mant : x1_mant;
  }

  uintmant_t ans_mant = input_not_output ? x0_mant : y0_mant;
  if(ans_mant == 0)
    return T(0.0f);
  else {
    int shift = clz64(ans_mant) - (64-FloatLayout<T>::mantissa_bits-1);
    int ans_sign = input_not_output ? x_sign : y_sign;
    int ans_exp = xy_exp - shift;
    ans_mant <<= shift;
    return makeFloat<T>(ans_sign, ans_exp, ans_mant & mant_mask);
  }
}
}

namespace {
template<typename T>
__host__ __device__ T genInOutFloatPreMulSum(
    bool input_not_output, int rank_n, int rank_me, uint64_t seed, intptr_t index
  ) {
  constexpr int exp_lo = 1 + FloatLayout<T>::mantissa_bits;
  constexpr int exp_hi = (1<<FloatLayout<T>::exponent_bits)-1;
  using uintmant_t = typename std::conditional<(8*sizeof(T) > 32), uint64_t, uint32_t>::type;
  constexpr uintmant_t mant_mask = (uintmant_t(1) << FloatLayout<T>::mantissa_bits)-1;
  constexpr uintmant_t max_mant = 2*mant_mask + 1; // add implicit leading 1
  uint64_t rng = hashOf(seed, index);

  int y_sign = rng & 1;
  int y_exp = exp_lo + umul32hi(uint32_t(rng>>32), exp_hi-exp_lo);
  rng = mixBits(rng);
  int subrank_me0 = shuffleRank((rank_n+1)/2, rank_me/2, rng);
  int subrank_me1 = shuffleRank((rank_n+0)/2, rank_me/2, rng);

  // when ncclVerifiablePremulScalar() = 1.0 (rank_me%2 == 0)
  uintmant_t x0_mant, y0_mant;
  genSumXY((rank_n+1)/2, subrank_me0, rng, max_mant>>1, x0_mant, y0_mant);

  // when ncclVerifiablePremulScalar() = 2.0 (rank_me%2 == 1)
  uintmant_t x1_mant=0, y1_mant=0;
  if((rank_n+0)/2 != 0)
    genSumXY((rank_n+0)/2, subrank_me1, rng, max_mant>>2, x1_mant, y1_mant);

  uintmant_t x_mant = rank_me%2 == 0 ? x0_mant : x1_mant;
  uintmant_t y_mant = y0_mant + 2*y1_mant;
  uintmant_t ans_mant = input_not_output ? x_mant : y_mant;

  if(ans_mant == 0)
    return T(0.0f);
  else {
    int shift = clz64(ans_mant) - (64-FloatLayout<T>::mantissa_bits-1);
    int ans_sign = y_sign;
    int ans_exp = y_exp - shift;
    ans_mant <<= shift;
    return makeFloat<T>(ans_sign, ans_exp, ans_mant & mant_mask);
  }
}
}

namespace {
template<typename T>
__host__ __device__ T genInOutFloatProd(
    bool input_not_output, int rank_n, int rank_me, uint64_t seed, intptr_t index
  ) {
  // Three kinds of contributions (values for x):
  // 1) x = random value: only one rank does this
  // 2) x = 2^n: random positive n
  // 3) x = 1
  // Since only one rank submits a random value, the result of the product
  // will have the same mantissa as that value but with an exponent incorporating
  // the sum of the exponents from case (2)

  uint64_t rng = hashOf(seed, index);
  rank_me = shuffleRank(rank_n, rank_me, rng);
  int y_sign = (rank_n/2)%2;
  int x_sign = rank_me%2;

  constexpr unsigned max_exp = -1 + (1<<(FloatLayout<T>::exponent_bits-1));
  unsigned x_exp=0, y_exp=0;
  genSumXY(rank_n, rank_me, rng, max_exp, x_exp, y_exp);
  x_exp += FloatLayout<T>::exponent_bias;
  y_exp += FloatLayout<T>::exponent_bias;

  constexpr uint64_t mant_mask = (uint64_t(1)<<FloatLayout<T>::mantissa_bits)-1;
  uint64_t y_mant = rng & mant_mask;
  if (y_mant == 0) y_mant = 1;

  return makeFloat<T>(
    input_not_output ? x_sign : y_sign,
    input_not_output ? x_exp : y_exp,
    !input_not_output || rank_me==0 ? y_mant : 0
  );
}
}

////////////////////////////////////////////////////////////////////////////////
// What follows is lots of overloads for genInput/genOutput to generate data

namespace {
// General case for integral data for all ops but ReduceNil/premulsum
template<typename T, typename ReduceFn,
         typename = typename std::enable_if<
             !std::is_same<ReduceFn, ReduceNil>::value
           >::type>
__host__ __device__ void genInput(
    T &ans, ReduceFn, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::true_type /*integral*/
  ) {
  (void)rank_n; // silence unused warnings
  union { uint64_t bits; T tmp; };
  bits = uint64_t(-1)>>(64 - 8*sizeof(T));
  bits &= hashOf(index ^ index<<16 ^ rank_me, seed);
  // make sure we never return 0 in products
  ans = std::is_same<ReduceFn, ReduceProd>::value && bits == 0 ? T(1) : tmp;
}
}

////////////////////////////////////////////////////////////////////////////////
// Dumb/generic case for genOutput just reduces results of genInput

namespace {
template<typename T, typename ReduceFn, bool IsIntegral>
__host__ __device__ void genOutput(
    T &ans, ReduceFn op, int rank_n, uint64_t seed, intptr_t index,
    std::integral_constant<bool, IsIntegral>
  ) {
  T acc = genInput<T>(op, rank_n, 0, seed, index);
  acc = op.preOp(acc, 0);
  for(int r=1; r < rank_n; r++)
    acc = op(acc, op.preOp(genInput<T>(op, rank_n, r, seed, index), r));
  ans = op.postOp(acc);
}
}

////////////////////////////////////////////////////////////////////////////////
// Nil reduction (byte copy functions). Optimized to assume rank_n=1

// genInput specialization for integer ReduceNil.
namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceNil, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::true_type /*integral*/
  ) {
  (void)rank_n, (void)rank_me; // silence unused warnings
  union { uint64_t bits; T tmp; };
  bits = mixBits(seed ^ index);
  bits >>= 64 - 8*sizeof(T);
  bits &= uint64_t(-1)>>(64 - 8*sizeof(T));
  ans = tmp;
}

// genInput specialization for floating point ReduceNil.
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceNil, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  (void)rank_n; // silence unused warnings
  constexpr uint64_t mant_mask = (uint64_t(1) << FloatLayout<T>::mantissa_bits)-1;
  uint64_t rng = hashOf(index ^ index<<16 ^ rank_me, seed);
  int sign = rng & 1;
  rng ^= rng>>1;
  int exp = rng & ((1<<(FloatLayout<T>::exponent_bits-1))-1);
  exp += 1<<(FloatLayout<T>::exponent_bits-2);
  rng ^= rng >> FloatLayout<T>::exponent_bits;
  uint64_t mant = rng & mant_mask;
  ans = makeFloat<T>(sign, exp, mant);
}

template<typename T, typename ReduceFn, bool IsIntegral>
__host__ __device__ void genOutput(
    T &ans, ReduceNil op, int rank_n, uint64_t seed, intptr_t index,
    std::integral_constant<bool, IsIntegral>
  ) {
  ans = genInput<T>(op, rank_n, 0, seed, index);
}
}

////////////////////////////////////////////////////////////////////////////////
// Sum of float

namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceSum, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatSum<T>(/*input_not_output=*/true, rank_n, rank_me, seed, index, /*same_sign=*/false);
}

template<typename T>
__host__ __device__ void genOutput(
    T &ans, ReduceSum, int rank_n, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatSum<T>(/*input_not_output=*/false, rank_n, 0, seed, index, /*same_sign=*/false);
}
}

////////////////////////////////////////////////////////////////////////////////
// Product of float

namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceProd, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatProd<T>(/*input_not_output=*/true, rank_n, rank_me, seed, index);
}

template<typename T>
__host__ __device__ void genOutput(
    T &ans, ReduceProd, int rank_n, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatProd<T>(/*input_not_output=*/false, rank_n, 0, seed, index);
}
}

////////////////////////////////////////////////////////////////////////////////
// PreMulSum of int/float

namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReducePreMulSum, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::true_type integral
  ) {
  genInput(ans, ReduceSum(), rank_n, rank_me, seed, index, integral);
}

// No genOutput overload specific to premulsum(int), just use generic case.

template<typename T>
__host__ __device__ void genInput(
    T &ans, ReducePreMulSum, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatPreMulSum<T>(/*input_not_output=*/true, rank_n, rank_me, seed, index);
}

template<typename T>
__host__ __device__ void genOutput(
    T &ans, ReducePreMulSum, int rank_n, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  ans = genInOutFloatPreMulSum<T>(/*input_not_output=*/false, rank_n, 0, seed, index);
}
}

/////////////////////////////////////////////////////////////////////////////////
// Average of float

namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceAvg, int rank_n, int rank_me, uint64_t rng, intptr_t index,
    std::false_type /*integral*/
  ) {
  // We can't control the nranks divisor in avareages so to control error we
  // limit to two ranks contributing non-zero values. This way there is no ambiguity
  // of summation.
  int r = shuffleRank(rank_n, rank_me, rng);
  uint64_t m = (rng*(r ? 0xbeef : 1)) & ((1ul<<FloatLayout<T>::mantissa_bits)-1);
  ans = r < 2 ? castTo<T>(1+m) : castTo<T>((uint64_t)0);
}

template<typename T>
__host__ __device__ void genOutput(
    T &ans, ReduceAvg, int rank_n, uint64_t rng, intptr_t index,
    std::false_type /*integral*/
  ) {
  shuffleRank(rank_n, -1, rng);
  uint64_t m0 = (rng*(0 ? 0xbeef : 1)) & ((1ul<<FloatLayout<T>::mantissa_bits)-1);
  uint64_t m1 = (rng*(1 ? 0xbeef : 1)) & ((1ul<<FloatLayout<T>::mantissa_bits)-1);
  if (rank_n == 1) {
    ans = castTo<T>(1+m0);
  } else {
    // NCCL varies which datatype it does the muls with depending on __CUDA_ARCH__.
    // We account for this by using a tolerance of 2 ulps during the verification.
    using TMul = typename std::conditional<(sizeof(T) < sizeof(double)), float, double>::type;
    ans = ReduceSum()((T)(TMul(1+m0)*TMul(1.0/rank_n)),
                      (T)(TMul(1+m1)*TMul(1.0/rank_n)));
  }
}
}

/////////////////////////////////////////////////////////////////////////////////
// min/max of float

namespace {
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceMin, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type integral
  ) {
  genInput<T>(ans, ReduceMax(), rank_n, rank_me, seed, index, integral);
}
template<typename T>
__host__ __device__ void genInput(
    T &ans, ReduceMax, int rank_n, int rank_me, uint64_t seed, intptr_t index,
    std::false_type /*integral*/
  ) {
  (void)rank_n; // silence unused warnings
  constexpr uint64_t mant_mask = (uint64_t(1) << FloatLayout<T>::mantissa_bits)-1;
  uint64_t rng = hashOf(index ^ index<<16 ^ rank_me, seed);
  int sign = rng & 1;
  rng ^= rng>>1;
  int exp = rng & ((1<<(FloatLayout<T>::exponent_bits-1))-1);
  exp += 1<<(FloatLayout<T>::exponent_bits-2);
  rng ^= rng >> FloatLayout<T>::exponent_bits;
  uint64_t mant = rng & mant_mask;
  ans = makeFloat<T>(sign, exp, mant);
}

// No genOutput overload specific to floating point min/max, just use generic case.
}

///////////////////////////////////////////////////////////////////////////////
// Entry API for genInput/genOutput

namespace {
template<typename T, typename ReduceFn>
__host__ __device__ T genInput(
    ReduceFn op, int rank_n, int rank_me, uint64_t seed, intptr_t index
  ) {
  T ans;
  genInput(ans, op, rank_n, rank_me, seed, index,
    std::integral_constant<bool, IsIntegral<T>::value>());
  return ans;
}

template<typename T, typename ReduceFn>
__host__ __device__ T genOutput(
    ReduceFn op, int rank_n, uint64_t seed, intptr_t index
  ) {
  T ans;
  genOutput(ans, op, rank_n, seed, index,
    std::integral_constant<bool, IsIntegral<T>::value>());
  return ans;
}
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T, typename ReduceFn>
__global__ void __launch_bounds__(512, 1) prepareInput2(
    T *elts, intptr_t elt_n, ReduceFn op, int rank_n, int rank_me,
    uint64_t seed, intptr_t elt_ix0
  ) {
  intptr_t i0 = blockIdx.x*(elt_n/gridDim.x);
  i0 += blockIdx.x < elt_n%gridDim.x ? blockIdx.x : elt_n%gridDim.x;
  intptr_t i1 = (blockIdx.x+1)*(elt_n/gridDim.x);
  i1 += blockIdx.x+1 < elt_n%gridDim.x ? blockIdx.x+1 : elt_n%gridDim.x;
  intptr_t i = i0 + threadIdx.x;
  while(i < i1) {
    elts[i] = genInput<T>(op, rank_n, rank_me, seed, elt_ix0+i);
    #if 0
    T output = genOutput<T>(op, rank_n, seed, elt_ix0+i);
    printf("prepareInput2 T=%d seed=0x%llx r=%d ix=%lld x=%g output=%g elts=%p\n",
      std::is_same<T,int>::value, (long long)seed, int(rank_me), (long long)i, (float)elts[i], (float)output, elts);
    #endif
    i += blockDim.x;
  }
}

template<typename ReduceOp>
cudaError_t prepareInput1(
    void *elts, intptr_t elt_n, int elt_ty, ReduceOp op, int rank_n, int rank_me,
    uint64_t seed, intptr_t elt_ix0, cudaStream_t stream
  ) {
  void const *fn = nullptr;
  switch(elt_ty) {
  case ncclInt8: fn = (void const*)&prepareInput2<int8_t, ReduceOp>; break;
  case ncclUint8: fn = (void const*)&prepareInput2<uint8_t, ReduceOp>; break;
  case ncclInt32: fn = (void const*)&prepareInput2<int32_t, ReduceOp>; break;
  case ncclUint32: fn = (void const*)&prepareInput2<uint32_t, ReduceOp>; break;
  case ncclInt64: fn = (void const*)&prepareInput2<int64_t, ReduceOp>; break;
  case ncclUint64: fn = (void const*)&prepareInput2<uint64_t, ReduceOp>; break;
  case ncclFloat16: fn = (void const*)&prepareInput2<half, ReduceOp>; break;
  #if HAVE_ncclBfloat16
  case ncclBfloat16: fn = (void const*)&prepareInput2<__nv_bfloat16, ReduceOp>; break;
  #endif
  #if HAVE_ncclFloat8
  case ncclFloat8e4m3: fn = (void const*)&prepareInput2<__nv_fp8_e4m3, ReduceOp>; break;
  case ncclFloat8e5m2: fn = (void const*)&prepareInput2<__nv_fp8_e5m2, ReduceOp>; break;
  #endif
  case ncclFloat32: fn = (void const*)&prepareInput2<float, ReduceOp>; break;
  case ncclFloat64: fn = (void const*)&prepareInput2<double, ReduceOp>; break;
  default: assert(0); return cudaErrorInvalidValue;
  }
  #undef CASE_TY
  dim3 grid = {1, 1, 1};
  grid.x = (unsigned int)std::min<intptr_t>(32, (elt_n + 4*512-1)/(4*512));
  dim3 block = {512, 1, 1};
  void *args[7] = {&elts, &elt_n, &op, &rank_n, &rank_me, &seed, &elt_ix0};
  if (grid.x == 0) return cudaSuccess;
  return cudaLaunchKernel(fn, grid, block, args, 0, stream);
}
}

cudaError_t ncclVerifiablePrepareInput(
    void *elts, intptr_t elt_n, int elt_ty, int red_op, int rank_n, int rank_me,
    uint64_t seed, intptr_t elt_ix0, cudaStream_t stream
  ) {
  #define CASE_OP(op) \
    if(rank_n == 1) \
      return prepareInput1(elts, elt_n, elt_ty, ReduceNil(), rank_n, rank_me, seed, elt_ix0, stream); \
    else \
      return prepareInput1(elts, elt_n, elt_ty, op, rank_n, rank_me, seed, elt_ix0, stream); \
    break;
  switch(red_op) {
  case ncclSum: CASE_OP(ReduceSum())
  case ncclMin: CASE_OP(ReduceMin())
  case ncclMax: CASE_OP(ReduceMax())
  case ncclProd: CASE_OP(ReduceProd())
  #if HAVE_ncclAvg
  case ncclAvg: CASE_OP(ReduceAvg{rank_n})
  #endif
  #if HAVE_ncclPreMulSum
  default: CASE_OP(ReducePreMulSum())
  #endif
  }
  #undef CASE_OP
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T, typename ReduceFn>
__global__ void __launch_bounds__(512, 1) prepareExpected2(
    T *elts, intptr_t elt_n, ReduceFn op, int rank_n,
    uint64_t seed, intptr_t elt_ix0
  ) {
  intptr_t i0 = blockIdx.x*(elt_n/gridDim.x);
  i0 += blockIdx.x < elt_n%gridDim.x ? blockIdx.x : elt_n%gridDim.x;
  intptr_t i1 = (blockIdx.x+1)*(elt_n/gridDim.x);
  i1 += blockIdx.x+1 < elt_n%gridDim.x ? blockIdx.x+1 : elt_n%gridDim.x;
  intptr_t i = i0 + threadIdx.x;
  while(i < i1) {
    elts[i] = genOutput<T>(op, rank_n, seed, elt_ix0+i);
    #if 0
    printf("prepareExpected2 seed=0x%llx ix=%lld x=%g elts=%p\n",
      (long long)seed, (long long)(elt_ix0+i), (float)elts[i], elts);
    #endif
    i += blockDim.x;
  }
}

template<typename ReduceOp>
cudaError_t prepareExpected1(
    void *elts, intptr_t elt_n, int elt_ty, ReduceOp op, int rank_n,
    uint64_t seed, intptr_t elt_ix0, cudaStream_t stream
  ) {
  void const *fn = nullptr;
  switch(elt_ty) {
  case ncclInt8: fn = (void const*)&prepareExpected2<int8_t, ReduceOp>; break;
  case ncclUint8: fn = (void const*)&prepareExpected2<uint8_t, ReduceOp>; break;
  case ncclInt32: fn = (void const*)&prepareExpected2<int32_t, ReduceOp>; break;
  case ncclUint32: fn = (void const*)&prepareExpected2<uint32_t, ReduceOp>; break;
  case ncclInt64: fn = (void const*)&prepareExpected2<int64_t, ReduceOp>; break;
  case ncclUint64: fn = (void const*)&prepareExpected2<uint64_t, ReduceOp>; break;
  case ncclFloat16: fn = (void const*)&prepareExpected2<half, ReduceOp>; break;
  #if HAVE_ncclBfloat16
  case ncclBfloat16: fn = (void const*)&prepareExpected2<__nv_bfloat16, ReduceOp>; break;
  #endif
  #if HAVE_ncclFloat8
  case ncclFloat8e4m3: fn = (void const*)&prepareExpected2<__nv_fp8_e4m3, ReduceOp>; break;
  case ncclFloat8e5m2: fn = (void const*)&prepareExpected2<__nv_fp8_e5m2, ReduceOp>; break;
  #endif
  case ncclFloat32: fn = (void const*)&prepareExpected2<float, ReduceOp>; break;
  case ncclFloat64: fn = (void const*)&prepareExpected2<double, ReduceOp>; break;
  default: assert(0); return cudaErrorInvalidValue;
  }
  #undef CASE_TY
  dim3 grid = {1, 1, 1};
  grid.x = (unsigned int)std::min<intptr_t>(32, (elt_n + 4*512-1)/(4*512));
  dim3 block = {512, 1, 1};
  void *args[6] = {&elts, &elt_n, &op, &rank_n, &seed, &elt_ix0};
  if (grid.x == 0) return cudaSuccess;
  return cudaLaunchKernel(fn, grid, block, args, 0, stream);
}
}

cudaError_t ncclVerifiablePrepareExpected(
    void *elts, intptr_t elt_n, int elt_ty, int red_op, int rank_n,
    uint64_t seed, intptr_t elt_ix0, cudaStream_t stream
  ) {
  #define CASE_OP(op) \
    if(rank_n == 1) \
      return prepareExpected1(elts, elt_n, elt_ty, ReduceNil(), rank_n, seed, elt_ix0, stream); \
    else \
      return prepareExpected1(elts, elt_n, elt_ty, op, rank_n, seed, elt_ix0, stream); \
    break;
  switch(red_op) {
  case ncclSum: CASE_OP(ReduceSum())
  case ncclMin: CASE_OP(ReduceMin())
  case ncclMax: CASE_OP(ReduceMax())
  case ncclProd: CASE_OP(ReduceProd())
  #if HAVE_ncclAvg
  case ncclAvg: CASE_OP(ReduceAvg{rank_n})
  #endif
  #if HAVE_ncclPreMulSum
  default: CASE_OP(ReducePreMulSum())
  #endif
  }
  #undef CASE_OP
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T>
__host__ __device__  uint64_t calcDelta(T a, T b) {
  union { T t; uint8_t i1; uint16_t i2; uint32_t i4; uint64_t i8; } x, y;
  x.t = a;
  y.t = b;
  switch(sizeof(T)) {
  case 1:  return x.i1 < y.i1 ? y.i1 - x.i1 : x.i1 - y.i1;
  case 2:  return x.i2 < y.i2 ? y.i2 - x.i2 : x.i2 - y.i2;
  case 4:  return x.i4 < y.i4 ? y.i4 - x.i4 : x.i4 - y.i4;
  default: return x.i8 < y.i8 ? y.i8 - x.i8 : x.i8 - y.i8;
  }
}
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T>
__global__ void __launch_bounds__(512, 1) verifyPrepared(
    T const *results, T const *expected, intptr_t elt_n, unsigned tolerance, int64_t *bad_elt_n
  ) {
  intptr_t i0 = blockIdx.x*(elt_n/gridDim.x);
  i0 += blockIdx.x < elt_n%gridDim.x ? blockIdx.x : elt_n%gridDim.x;
  intptr_t i1 = (blockIdx.x+1)*(elt_n/gridDim.x);
  i1 += blockIdx.x+1 < elt_n%gridDim.x ? blockIdx.x+1 : elt_n%gridDim.x;
  intptr_t i = i0 + threadIdx.x;
  int64_t bad = 0;

  while(i < i1) {
    T a = results[i], b = expected[i];
    T delta = a < b ? b - a : a - b;
    bad += tolerance < delta ? 1 : 0;
    #if 0
      if(tolerance < delta) {
        printf("verifyPrepared ix=%lld got=%g exp=%g tol=%d\n", (long long)i, (float)results[i], (float)expected[i], tolerance);
      }
    #endif
    i += blockDim.x;
  }
  asm volatile("red.global.add.u64 [%0],%1;" :: "l"(bad_elt_n), "l"(bad) : "memory");
}

cudaError_t verifyPrepared1(int bytePerElt,
    void const *results, void const *expected, intptr_t elt_n, unsigned tolerance, int64_t *bad_elt_n, cudaStream_t stream, int block_n
  ) {
  void const *fn = nullptr;
  switch(bytePerElt) {
  case 1: fn = (void const*)&verifyPrepared<uint8_t>; break;
  case 2: fn = (void const*)&verifyPrepared<uint16_t>; break;
  case 4: fn = (void const*)&verifyPrepared<uint32_t>; break;
  case 8: fn = (void const*)&verifyPrepared<uint64_t>; break;
  default: assert(0); return cudaErrorInvalidValue;
  }
  dim3 grid = {(unsigned int)block_n, 1, 1};
  dim3 block = {512, 1, 1};
  void *args[5] = {&results, &expected, &elt_n, &tolerance, &bad_elt_n};
  if (grid.x == 0) return cudaSuccess;
  return cudaLaunchKernel(fn, grid, block, args, 0, stream);
}

template<typename T, typename Uint, typename ReduceFn>
__global__ void __launch_bounds__(512, 1) verifyInline2(
    T const *results, intptr_t elt_n, ReduceFn op, int rank_n, uint64_t seed,
    intptr_t elt_ix0, unsigned tolerance, int64_t *bad_elt_n
  ) {
  intptr_t i0 = blockIdx.x*(elt_n/gridDim.x);
  i0 += blockIdx.x < elt_n%gridDim.x ? blockIdx.x : elt_n%gridDim.x;
  intptr_t i1 = (blockIdx.x+1)*(elt_n/gridDim.x);
  i1 += blockIdx.x+1 < elt_n%gridDim.x ? blockIdx.x+1 : elt_n%gridDim.x;
  intptr_t i = i0 + threadIdx.x;
  int64_t bad = 0;

  while(i < i1) {
    union { T t; Uint u; } a, b;
    a.t = results[i];
    b.t = genOutput<T>(op, rank_n, seed, elt_ix0+i);
    Uint delta = a.u < b.u ? b.u - a.u : a.u - b.u;
    bad += tolerance < delta ? 1 : 0;
    #if 0
      T input = genInput<T>(op, rank_n, 0, seed, elt_ix0+i);
      if(tolerance < delta) {
        printf("verifyInline2 fail T=%d ix=%lld got=%g exp=%g input=%g\n",
          std::is_same<T,int>::value, (long long)i, (float)a.t, (float)b.t, (float)input);
      } else {
        printf("verifyInline2 pass T=%d ix=%lld got=%g exp=%g input=%g\n",
          std::is_same<T,int>::value, (long long)i, (float)a.t, (float)b.t, (float)input);
      }
    #endif
    i += blockDim.x;
  }
  asm volatile("red.global.add.u64 [%0],%1;" :: "l"(bad_elt_n), "l"(bad) : "memory");
}

template<typename T, typename Uint>
cudaError_t verifyInline1(
    T const *results, intptr_t elt_n, int red_op, int rank_n, uint64_t seed, intptr_t elt_ix0,
    unsigned tolerance, int64_t *bad_elt_n, cudaStream_t stream, int block_n
  ) {
  void const *fn = nullptr;
  ReduceNil opnil;
  ReduceSum opsum;
  ReduceMin opmin;
  ReduceMax opmax;
  ReduceProd opprod;
  ReduceAvg opavg{rank_n};
  ReducePreMulSum oppremulsum;
  void *args[8] = {&results, &elt_n, nullptr, &rank_n, &seed, &elt_ix0, &tolerance, &bad_elt_n};
  #define CASE_OP(op) \
    if(rank_n == 1) { \
      fn = (void const*)&verifyInline2<T, Uint, ReduceNil>; \
      args[2] = &opnil; \
    } else { \
      fn = (void const*)&verifyInline2<T, Uint, decltype(op)>; \
      args[2] = &op; \
    } break;
  switch(red_op) {
  case ncclSum: CASE_OP(opsum)
  case ncclMin: CASE_OP(opmin)
  case ncclMax: CASE_OP(opmax)
  case ncclProd: CASE_OP(opprod)
  #if HAVE_ncclAvg
  case ncclAvg: CASE_OP(opavg)
  #endif
  #if HAVE_ncclPreMulSum
  default: CASE_OP(oppremulsum)
  #endif
  }
  #undef CASE_OP
  dim3 grid = {(unsigned int)block_n, 1, 1};
  dim3 block = {512, 1, 1};
  if (grid.x == 0) return cudaSuccess;
  return cudaLaunchKernel(fn, grid, block, args, 0, stream);
}
}

cudaError_t ncclVerifiableVerify(
    void const *results, void const *expected, intptr_t elt_n, int elt_ty,
    int red_op, int rank_n, uint64_t seed, intptr_t elt_ix0,
    int64_t *bad_elt_n, cudaStream_t stream
  ) {
  bool floating = elt_ty == ncclFloat16 || elt_ty == ncclFloat32 || elt_ty == ncclFloat64;
  #if HAVE_ncclBfloat16
    floating |= elt_ty == ncclBfloat16;
  #endif
  #if HAVE_ncclFloat8
    floating |= elt_ty == ncclFloat8e4m3;
    floating |= elt_ty == ncclFloat8e5m2;
  #endif
  
  unsigned tolerance = 0;
  #if HAVE_ncclAvg
  if (floating && red_op == ncclAvg) {
    // Average does it's pre-multiplies in an unspecified floating point format
    // (could be the actual type T or float or half). That means the premultiply
    // verify does could generate a discrepancy in the least mantissa digit. After
    // adding those two (since avg only has two non-zero contributions) we could
    // be off by a distance of 2 units.
    tolerance = 2;
  }
  #endif

  int block_n = std::min<intptr_t>(32, (elt_n + 4*512-1)/(4*512));

  *bad_elt_n = 0;
  #define CASE_TY(T, Uint) { \
      if(expected != nullptr) { \
        return verifyPrepared1(sizeof(T), results, expected, elt_n, tolerance, bad_elt_n, stream, block_n); \
      } else { \
        return verifyInline1<T, Uint>((T const*)results, elt_n, red_op, rank_n, seed, elt_ix0, tolerance, bad_elt_n, stream, block_n); \
      } \
    } break;
  switch(elt_ty) {
  case ncclInt8: CASE_TY(int8_t, uint8_t)
  case ncclUint8: CASE_TY(uint8_t, uint8_t)
  case ncclInt32: CASE_TY(int32_t, uint32_t)
  case ncclUint32: CASE_TY(uint32_t, uint32_t)
  case ncclInt64: CASE_TY(int64_t, uint64_t)
  case ncclUint64: CASE_TY(uint64_t, uint64_t)
  case ncclFloat16: CASE_TY(half, uint16_t)
  #if HAVE_ncclFloat8
  case ncclFloat8e4m3: CASE_TY(__nv_fp8_e4m3, uint8_t)
  case ncclFloat8e5m2: CASE_TY(__nv_fp8_e5m2, uint8_t)
  #endif
  #if HAVE_ncclBfloat16
  case ncclBfloat16: CASE_TY(__nv_bfloat16, uint16_t)
  #endif
  case ncclFloat32: CASE_TY(float, uint32_t)
  case ncclFloat64: CASE_TY(double, uint64_t)
  default: assert(0); return cudaErrorInvalidValue;
  }
  #undef CASE_TY
}

////////////////////////////////////////////////////////////////////////////////

namespace {
template<typename T, typename Op>
__device__ void sweep2(int ty, char const *tyname, Op op, char const *opname, int rank_n) {
  //if(!std::is_same<T,half>::value) return;
  //if(!std::is_same<Op,ReduceProd>::value) return;
  //if(rank_n!=3) return;

  unsigned tolerance = !IsIntegral<T>::value && std::is_same<Op,ReduceAvg>::value ? 2 : 0;
  uint64_t seed = 0xc8e2bed69766d533;

  for(int ix=threadIdx.x; ix < 10000; ix+=blockDim.x) {
    //if(ix!=387) continue;
    T y = genOutput<T>(op, rank_n, seed, ix);
    T sum;
    for(int r=0; r < rank_n; r++) {
      T x = genInput<T>(op, rank_n, r, seed, ix);
      x = op.preOp(x, r);
      sum = r==0 ? x : op(sum, inhibit(x));
      //std::printf("x = %llx, sum = %llx\n", bitsOf(x), bitsOf(sum));
    }
    sum = op.postOp(sum);
    if(tolerance < calcDelta(sum, y)) {
      std::printf(
        //"%10g != %10g  :  T=%-8s op=%-9s rank_n=%-1d ix=%-1d\n",
        "%llx != %llx  :  T=%-8s op=%-9s rank_n=%-1d ix=%-1d\n",
        *(long long*)&sum, *(long long*)&y, tyname, opname, rank_n, ix
      );
    }
  }
}

template<typename T>
__device__ void sweep1(int ty, char const *tyname) {
  for(int i=0; i < 10; i++) {
    int rank_n = (1<<i) + i;
    sweep2<T>(ty, tyname, ReduceSum(), "sum", rank_n);
    sweep2<T>(ty, tyname, ReduceProd(), "prod", rank_n);
    sweep2<T>(ty, tyname, ReduceMin(), "min", rank_n);
    sweep2<T>(ty, tyname, ReduceMax(), "max", rank_n);
    sweep2<T>(ty, tyname, ReducePreMulSum(), "premulsum", rank_n);
    sweep2<T>(ty, tyname, ReduceAvg{rank_n}, "avg", rank_n);
  }
}

__global__ void __launch_bounds__(512, 1) sweep() {
  sweep1<int8_t>(ncclInt8, "int8");
  sweep1<uint8_t>(ncclUint8, "uint8");
  sweep1<int32_t>(ncclInt32, "int32");
  sweep1<uint32_t>(ncclUint32, "uint32");
  sweep1<int64_t>(ncclInt64, "int64");
  sweep1<uint64_t>(ncclUint64, "uint64");
  sweep1<half>(ncclFloat16, "half");
  #if HAVE_ncclFloat8
    sweep1<__nv_fp8_e4m3>(ncclBfloat16, "float8e4m3");
    sweep1<__nv_fp8_e5m2>(ncclBfloat16, "float8e5m2");
  #endif
  #if HAVE_ncclBfloat16
    sweep1<__nv_bfloat16>(ncclBfloat16, "bfloat16");
  #endif
  sweep1<float>(ncclFloat32, "float");
  sweep1<double>(ncclFloat64, "double");
}
}

void ncclVerifiableLaunchSelfTest() {
  sweep<<<1,512>>>();
}
