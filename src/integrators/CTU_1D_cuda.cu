/*! \file CTU_1D_cuda.cu
 *  \brief Definitions of the cuda CTU algorithm functions. */

#ifdef CUDA

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "../utils/gpu.hpp"
#include "../global/global.h"
#include "../global/global_cuda.h"
#include "../hydro/hydro_cuda.h"
#include "../integrators/CTU_1D_cuda.h"
#include "../reconstruction/pcm_cuda.h"
#include "../reconstruction/plmp_cuda.h"
#include "../reconstruction/plmc_cuda.h"
#include "../reconstruction/ppmp_cuda.h"
#include "../reconstruction/ppmc_cuda.h"
#include "../riemann_solvers/exact_cuda.h"
#include "../riemann_solvers/roe_cuda.h"
#include "../riemann_solvers/hllc_cuda.h"
#include "../cooling/cooling_cuda.h"
#include "../utils/error_handling.h"
#include "../io/io.h"



void CTU_Algorithm_1D_CUDA(Real *host_conserved0, Real *host_conserved1, Real *d_conserved, int nx, int x_off, int n_ghost, Real dx, Real xbound, Real dt, int n_fields)
{
  //Here, *host_conserved contains the entire
  //set of conserved variables on the grid
  //host_conserved0 contains the values at time n
  //host_conserved1 will contain the values at time n+1

  // Initialize dt values

  int n_cells = nx;
  int ny = 1;
  int nz = 1;

  // set the dimensions of the cuda grid
  ngrid = (n_cells + TPB - 1) / TPB;
  dim3 dimGrid(ngrid, 1, 1);
  dim3 dimBlock(TPB, 1, 1);

  if ( !memory_allocated ) {

    // allocate an array on the CPU to hold max_dti returned from each thread block
    CudaSafeCall( cudaHostAlloc(&host_dti_array, ngrid*sizeof(Real), cudaHostAllocDefault) );
    #ifdef COOLING_GPU
    CudaSafeCall( cudaHostAlloc(&host_dt_array, ngrid*sizeof(Real), cudaHostAllocDefault) );
    #endif

    // allocate memory on the GPU
    dev_conserved = d_conserved;
    //CudaSafeCall( cudaMalloc((void**)&dev_conserved, n_fields*n_cells*sizeof(Real)) );
    CudaSafeCall( cudaMalloc((void**)&Q_Lx, n_fields*n_cells*sizeof(Real)) );
    CudaSafeCall( cudaMalloc((void**)&Q_Rx, n_fields*n_cells*sizeof(Real)) );
    CudaSafeCall( cudaMalloc((void**)&F_x,   (n_fields)*n_cells*sizeof(Real)) );
    CudaSafeCall( cudaMalloc((void**)&dev_dti_array, ngrid*sizeof(Real)) );
    #if defined COOLING_GPU
    CudaSafeCall( cudaMalloc((void**)&dev_dt_array, ngrid*sizeof(Real)) );
    #endif

    #ifndef DYNAMIC_GPU_ALLOC
    // If memory is single allocated: memory_allocated becomes true and succesive timesteps won't allocate memory.
    // If the memory is not single allocated: memory_allocated remains Null and memory is allocated every timestep.
    memory_allocated = true;
    #endif
  }

  // copy the conserved variable array onto the GPU
  #ifndef HYDRO_GPU
  CudaSafeCall( cudaMemcpy(dev_conserved, host_conserved0, n_fields*n_cells*sizeof(Real), cudaMemcpyHostToDevice) );
  CudaCheckError();
  #endif // HYDRO_GPU


  // Step 1: Do the reconstruction
  #ifdef PCM
  hipLaunchKernelGGL(PCM_Reconstruction_1D, dimGrid, dimBlock, 0, 0, dev_conserved, Q_Lx, Q_Rx, nx, n_ghost, gama, n_fields);
  CudaCheckError();
  #endif
  #ifdef PLMP
  hipLaunchKernelGGL(PLMP_cuda, dimGrid, dimBlock, 0, 0, dev_conserved, Q_Lx, Q_Rx, nx, ny, nz, n_ghost, dx, dt, gama, 0, n_fields);
  CudaCheckError();
  #endif
  #ifdef PLMC
  hipLaunchKernelGGL(PLMC_cuda, dimGrid, dimBlock, 0, 0, dev_conserved, Q_Lx, Q_Rx, nx, ny, nz, n_ghost, dx, dt, gama, 0, n_fields);
  CudaCheckError();
  #endif
  #ifdef PPMP
  hipLaunchKernelGGL(PPMP_cuda, dimGrid, dimBlock, 0, 0, dev_conserved, Q_Lx, Q_Rx, nx, ny, nz, n_ghost, dx, dt, gama, 0, n_fields);
  CudaCheckError();
  #endif
  #ifdef PPMC
  hipLaunchKernelGGL(PPMC_cuda, dimGrid, dimBlock, 0, 0, dev_conserved, Q_Lx, Q_Rx, nx, ny, nz, n_ghost, dx, dt, gama, 0, n_fields);
  CudaCheckError();
  #endif


  // Step 2: Calculate the fluxes
  #ifdef EXACT
  hipLaunchKernelGGL(Calculate_Exact_Fluxes_CUDA, dimGrid, dimBlock, 0, 0, Q_Lx, Q_Rx, F_x, nx, ny, nz, n_ghost, gama, 0, n_fields);
  #endif
  #ifdef ROE
  hipLaunchKernelGGL(Calculate_Roe_Fluxes_CUDA, dimGrid, dimBlock, 0, 0, Q_Lx, Q_Rx, F_x, nx, ny, nz, n_ghost, gama, 0, n_fields);
  #endif
  #ifdef HLLC
  hipLaunchKernelGGL(Calculate_HLLC_Fluxes_CUDA, dimGrid, dimBlock, 0, 0, Q_Lx, Q_Rx, F_x, nx, ny, nz, n_ghost, gama, 0, n_fields);
  #endif
  CudaCheckError();

  #ifdef DE
  // Compute the divergence of Vel before updating the conserved array, this solves syncronization issues when adding this term on Update_Conserved_Variables
  hipLaunchKernelGGL(Partial_Update_Advected_Internal_Energy_1D, dimGrid, dimBlock, 0, 0,  dev_conserved, Q_Lx, Q_Rx, nx, n_ghost, dx, dt, gama, n_fields );
  #endif


  // Step 3: Update the conserved variable array
  hipLaunchKernelGGL(Update_Conserved_Variables_1D, dimGrid, dimBlock, 0, 0, dev_conserved, F_x, n_cells, x_off, n_ghost, dx, xbound, dt, gama, n_fields);
  CudaCheckError();


  // Sychronize the total and internal energy, if using dual-energy formalism
  #ifdef DE
  hipLaunchKernelGGL(Select_Internal_Energy_1D, dimGrid, dimBlock, 0, 0, dev_conserved, nx, n_ghost, n_fields);
  hipLaunchKernelGGL(Sync_Energies_1D, dimGrid, dimBlock, 0, 0, dev_conserved, n_cells, n_ghost, gama, n_fields);
  CudaCheckError();
  #endif

  #ifdef DYNAMIC_GPU_ALLOC
  // If memory is not single allocated then free the memory every timestep.
  Free_Memory_CTU_1D();
  #endif

  return;


}

void Free_Memory_CTU_1D() {

  // free the CPU memory
  CudaSafeCall( cudaFreeHost(host_dti_array) );
  #if defined COOLING_GPU
  CudaSafeCall( cudaFreeHost(host_dt_array) );
  #endif

  // free the GPU memory
  cudaFree(dev_conserved);
  cudaFree(Q_Lx);
  cudaFree(Q_Rx);
  cudaFree(F_x);
  cudaFree(dev_dti_array);
  #if defined COOLING_GPU
  cudaFree(dev_dt_array);
  #endif

}


#endif //CUDA
