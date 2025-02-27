CudaDWF::CudaDWF(const float mass, const float M5, const int Ls,
		 const int kernelType, const int L, const int T,
		 const bool precondition, const bool hermitian,
		 const Complex boundaryConditions[4], Complex* links)
  : CudaLinearOperator(L, T, precondition, hermitian, links, true)
{
  this->mass_ = mass;
  this->Ls_ = Ls;
  this->M5_ = M5;
  this->N = 12 * L * L * L * T * Ls;
  this->num_rows = precondition ? this->N / 2 : this->N;
  this->num_cols = precondition ? this->N / 2 : this->N;

  if (kernelType == 0)
    this->kernel_ = new CudaWilson(-M5, L, T, false, false, boundaryConditions,
				   this->links_, false);
  else if (kernelType == 1)
    this->kernel_ = new CudaHamberWu(-M5, L, T, false, false, boundaryConditions,
				     this->links_, false);
  else if (kernelType == 2)
    this->kernel_ = new CudaNaik(-M5, L, T, false, false, boundaryConditions,
				 this->links_, false);
  else
    this->kernel_ = new CudaWilson(-M5, L, T, false, false, boundaryConditions,
				   this->links_, false);
}



CudaDWF::~CudaDWF()
{
  delete this->kernel_;
}



void CudaDWF::apply(Complex* y, const Complex* x) const
{  
  int dimBlock;
  int dimGrid;

  int n = this->T_ * this->L_ * this->L_ * this->L_ * 12;

  Complex* z;
  cudaMalloc((void**) &z, n * sizeof(Complex));

  setGridAndBlockSize(dimBlock, dimGrid, n);

  for (int i = 0; i < this->Ls_; ++i) {
    this->kernel_->apply(y + i * n, x + i * n);
    saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, x + i * n, 1.0, n);
    
    if (i == 0) {
      applyPminus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1), this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else if (i == this->Ls_ - 1) {
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 2), this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, x, this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else {
      applyPminus<<<dimGrid,dimBlock>>>(z, x + (i + 1) * n, this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + (i - 1) * n, this->L_, this->T_);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
    }
  }

  cudaFree(z);
}



void CudaDWF::applyHermitian(Complex* y, const Complex* x) const
{
  this->apply(y, x);
  this->makeHermitian(y, y);
}



void CudaDWF::makeHermitian(Complex* y, const Complex* x) const
{
  if (this->precondition_) {    
    int n = this->Ls_ * this->T_ * this->L_ * this->L_ * this->L_ * 6;

    int dimBlock;
    int dimGrid;
    setGridAndBlockSize(dimBlock, dimGrid, n);

    Complex* z;
    cudaMalloc((void**) &z, n * sizeof(Complex));
    assignDev<<<dimGrid,dimBlock>>>(z, 0.0, n);

    this->applyEvenOddDagger(z, x);
    this->applyEvenEvenInv(z, z);
    this->applyOddEvenDagger(z, z);

    this->applyOddOdd(y, x);
    
    saxpyDev<<<dimGrid,dimBlock>>>(y, z, -1.0, n);

    cudaFree(z);
  }
  else {
    int dimBlock;
    int dimGrid;
    
    int n = this->T_ * this->L_ * this->L_ * this->L_ * 12;
    
    Complex* z;
    cudaMalloc((void**) &z, n * sizeof(Complex));

    // Temporary stores for 4D slices so we can reduce memory usage
    Complex* x0; // First slice
    cudaMalloc((void**) &x0, n * sizeof(Complex));
    Complex* xim1; // slice i - 1
    cudaMalloc((void**) &xim1, n * sizeof(Complex));
    Complex* xi; // ith slice
    cudaMalloc((void**) &xi, n * sizeof(Complex));

    setGridAndBlockSize(dimBlock, dimGrid, n);

    for (int i = 0; i < this->Ls_; ++i) {
      Complex* y_ptr = y + i * n; // The current 4D slices we're working on
      const Complex* x_ptr = x + i * n;
      assignDev<<<dimGrid, dimBlock>>>(xi, x_ptr, n);

      applyGamma5<<<dimGrid, dimBlock>>>(z, xi, this->L_, this->T_);
      this->kernel_->apply(y_ptr, z);
      saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, 1.0, n);
      applyGamma5<<<dimGrid,dimBlock>>>(y_ptr, y_ptr, this->L_, this->T_);    

      if (i == 0) {
	assignDev<<<dimGrid, dimBlock>>>(x0, xi, n);

	applyPplus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, -1.0, n);
	applyPminus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1),
					  this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, this->mass_, n);
      }
      else if (i == this->Ls_ - 1) {
	applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, -1.0, n);
	applyPplus<<<dimGrid,dimBlock>>>(z, x0, this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, this->mass_, n);
      }
      else {
	applyPplus<<<dimGrid,dimBlock>>>(z, x_ptr + n, this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, -1.0, n);
	applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_);
	saxpyDev<<<dimGrid,dimBlock>>>(y_ptr, z, -1.0, n);
      }
    
      assignDev<<<dimGrid, dimBlock>>>(xim1, xi, n);
    }

    cudaFree(z);
    cudaFree(x0);
    cudaFree(xi);
    cudaFree(xim1);
  }
}



void CudaDWF::makeEvenOdd(Complex* y, const Complex* x) const
{
  // Permutes the supplied 5D spinor, shuffling it so that all of the 5D
  // lattice sites are split according to whether they are even or odd

  int size4d = this->N / this->Ls_;
  int halfSize4d = size4d / 2;

  Complex* z = (Complex*) malloc(size4d * sizeof(Complex));

  for (int i = 0; i < this->Ls_; ++i) {
    this->kernel_->makeEvenOdd(z, x + i * size4d);

    if (i % 2 == 0) {
      for (int j = 0; j < halfSize4d; ++j)
	y[i * halfSize4d + j] = z[j];
      for (int j = 0; j < halfSize4d; ++j)
	y[(this->Ls_ + i) * halfSize4d + j] = z[halfSize4d + j];
    }
    else {
      for (int j = 0; j < halfSize4d; ++j)
	y[i * halfSize4d + j] = z[halfSize4d + j];
      for (int j = 0; j < halfSize4d; ++j)
	y[(this->Ls_ + i) * halfSize4d + j] = z[j];
    }
  }

  free(z);
}



void CudaDWF::removeEvenOdd(Complex* y, const Complex* x) const
{
  // Permutes the supplied 5D spinor, shuffling it back into lexicographic
  // order

  int size4d = this->N / this->Ls_;
  int halfSize4d = size4d / 2;

  Complex* z = (Complex*) malloc(size4d * sizeof(Complex));

  for (int i = 0; i < this->Ls_; ++i) {

    if (i % 2 == 0) {
      for (int j = 0; j < halfSize4d; ++j)
	z[j] = x[i * halfSize4d + j];
      for (int j = 0; j < halfSize4d; ++j)
	z[halfSize4d + j] = x[(this->Ls_ + i) * halfSize4d + j];
    }
    else {
      for (int j = 0; j < halfSize4d; ++j)
	z[halfSize4d + j] = x[i * halfSize4d + j];
      for (int j = 0; j < halfSize4d; ++j)
	z[j] = x[(this->Ls_ + i) * halfSize4d + j];
      
    }
    this->kernel_->removeEvenOdd(y + i * size4d, z);
  }

  free(z);
}



void CudaDWF::applyEvenEvenInv(Complex* y, const Complex* x) const
{
  // Applies the inverse of the even-even part of the domain wall operator
  // to the supplied spinor

  int halfSize4d = this->N / (2 * this->Ls_);

  int dimGrid;
  int dimBlock;
  setGridAndBlockSize(dimBlock, dimGrid, halfSize4d);

  Complex* inverseDiagonal;
  cudaMalloc((void**) &inverseDiagonal, 2 * halfSize4d * sizeof(Complex));
  assignDev<<<2 * dimGrid,dimBlock>>>(inverseDiagonal, 1.0, 2 * halfSize4d);
  this->kernel_->applyEvenEven(inverseDiagonal, inverseDiagonal);
  this->kernel_->applyOddOdd(inverseDiagonal + halfSize4d,
			     inverseDiagonal + halfSize4d);
  addConstantDev<<<2 * dimGrid,dimBlock>>>(inverseDiagonal, 1.0, 2 * halfSize4d);
  reciprocalDev<<<2 * dimGrid,dimBlock>>>(inverseDiagonal, inverseDiagonal,
					  2 * halfSize4d);

  for (int i = 0; i < this->Ls_; ++i) {
    if (i % 2 == 0)
      saxDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, x + i * halfSize4d,
				   inverseDiagonal, halfSize4d);
    else
      saxDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, x + i * halfSize4d,
				   inverseDiagonal + halfSize4d, halfSize4d);
  }

  cudaFree(inverseDiagonal);
}



void CudaDWF::applyOddOdd(Complex* y, const Complex* x) const
{
  // Applies the odd diagonal piece to the supplied spinor

  int halfSize4d = this->N / (2 * this->Ls_);

  int dimGrid;
  int dimBlock;
  setGridAndBlockSize(dimBlock, dimGrid, halfSize4d);

  Complex* z;
  cudaMalloc((void**) &z, halfSize4d * sizeof(Complex));

  for (int i = 0; i < this->Ls_; ++i) {
    if (i % 2 == 0) {
      this->kernel_->applyOddOdd(z, x + i * halfSize4d);
      assignDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, x + i * halfSize4d,
				      halfSize4d);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, z, 1.0, halfSize4d);
    }
    else {
      this->kernel_->applyEvenEven(z, x + i * halfSize4d);
      assignDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, x + i * halfSize4d,
				      halfSize4d);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * halfSize4d, z, 1.0, halfSize4d);
    }
  }

  cudaFree(z);
}



void CudaDWF::applyEvenOdd(Complex* y, const Complex* x) const
{  
  int dimBlock;
  int dimGrid;

  int n = this->T_ * this->L_ * this->L_ * this->L_ * 6;

  Complex* z;
  cudaMalloc((void**) &z, n * sizeof(Complex));

  setGridAndBlockSize(dimBlock, dimGrid, n);

  for (int i = 0; i < this->Ls_; ++i) {
    if (i % 2 == 0)
      this->kernel_->applyEvenOdd(y + i * n, x + i * n);
    else
      this->kernel_->applyOddEven(y + i * n, x + i * n);

    if (i == 0) {
      applyPminus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1), this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else if (i == this->Ls_ - 1) {
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 2), this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, x, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else {
      applyPminus<<<dimGrid,dimBlock>>>(z, x + (i + 1) * n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + (i - 1) * n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
    }
  }

  cudaFree(z);
}



void CudaDWF::applyEvenOddDagger(Complex* y, const Complex* x) const
{  
  int dimBlock;
  int dimGrid;

  int n = this->T_ * this->L_ * this->L_ * this->L_ * 6;

  Complex* z;
  cudaMalloc((void**) &z, n * sizeof(Complex));

  // Temporary stores for 4D slices so we can reduce memory usage
  Complex* x0; // First slice
  cudaMalloc((void**) &x0, n * sizeof(Complex));
  Complex* xim1; // slice i - 1
  cudaMalloc((void**) &xim1, n * sizeof(Complex));
  Complex* xi; // ith slice
  cudaMalloc((void**) &xi, n * sizeof(Complex));

  setGridAndBlockSize(dimBlock, dimGrid, n);

  for (int i = 0; i < this->Ls_; ++i) {
    assignDev<<<dimGrid,dimBlock>>>(xi, x + i * n, n);
    assignDev<<<dimGrid,dimBlock>>>(y + i * n, 0.0, n);
    assignDev<<<dimGrid,dimBlock>>>(z, 0.0, n);

    applyGamma5<<<dimGrid,dimBlock>>>(z, xi, this->L_, this->T_ / 2);
    if (i % 2 == 0)
      this->kernel_->applyEvenOdd(y + i * n, z);
    else
      this->kernel_->applyOddEven(y + i * n, z);
    applyGamma5<<<dimGrid,dimBlock>>>(y + i * n, y + i * n, this->L_, this->T_ / 2);

    if (i == 0) {
      assignDev<<<dimGrid,dimBlock>>>(x0, xi, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1), this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else if (i == this->Ls_ - 1) {
      applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x0, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else {
      applyPplus<<<dimGrid,dimBlock>>>(z, x + (i + 1) * n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
    }
    
    assignDev<<<dimGrid, dimBlock>>>(xim1, xi, n);
  }

  cudaFree(z);
  cudaFree(x0);
  cudaFree(xi);
  cudaFree(xim1);
}



void CudaDWF::applyOddEven(Complex* y, const Complex* x) const
{  
  int dimBlock;
  int dimGrid;

  int n = this->T_ * this->L_ * this->L_ * this->L_ * 6;

  Complex* z;
  cudaMalloc((void**) &z, n * sizeof(Complex));

  // Temporary stores for 4D slices so we can reduce memory usage
  Complex* x0; // First slice
  cudaMalloc((void**) &x0, n * sizeof(Complex));
  Complex* xim1; // slice i - 1
  cudaMalloc((void**) &xim1, n * sizeof(Complex));
  Complex* xi; // ith slice
  cudaMalloc((void**) &xi, n * sizeof(Complex));

  setGridAndBlockSize(dimBlock, dimGrid, n);

  assignDev<<<dimGrid,dimBlock>>>(z, 0.0, n);

  for (int i = 0; i < this->Ls_; ++i) {
    assignDev<<<dimGrid, dimBlock>>>(xi, x + i * n, n);
    assignDev<<<dimGrid, dimBlock>>>(y + i * n, 0.0, n);
    if (i % 2 == 0)
      this->kernel_->applyOddEven(y + i * n, xi);
    else
      this->kernel_->applyEvenOdd(y + i * n, xi);

    if (i == 0) {
      assignDev<<<dimGrid, dimBlock>>>(x0, xi, n);

      applyPminus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1), this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else if (i == this->Ls_ - 1) {
      applyPplus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, x0, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else {
      applyPminus<<<dimGrid,dimBlock>>>(z, x + (i + 1) * n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
    }
    
    assignDev<<<dimGrid, dimBlock>>>(xim1, xi, n);
  }

  cudaFree(z);
  cudaFree(x0);
  cudaFree(xi);
  cudaFree(xim1);
}



void CudaDWF::applyOddEvenDagger(Complex* y, const Complex* x) const
{  
  int dimBlock;
  int dimGrid;

  int n = this->T_ * this->L_ * this->L_ * this->L_ * 6;

  Complex* z;
  cudaMalloc((void**) &z, n * sizeof(Complex));

  // Temporary stores for 4D slices so we can reduce memory usage
  Complex* x0; // First slice
  cudaMalloc((void**) &x0, n * sizeof(Complex));
  Complex* xim1; // slice i - 1
  cudaMalloc((void**) &xim1, n * sizeof(Complex));
  Complex* xi; // ith slice
  cudaMalloc((void**) &xi, n * sizeof(Complex));

  setGridAndBlockSize(dimBlock, dimGrid, n);

  for (int i = 0; i < this->Ls_; ++i) {
    assignDev<<<dimGrid,dimBlock>>>(xi, x + i * n, n);
    assignDev<<<dimGrid,dimBlock>>>(y + i * n, 0.0, n);
    assignDev<<<dimGrid,dimBlock>>>(z, 0.0, n);

    applyGamma5<<<dimGrid,dimBlock>>>(z, xi, this->L_, this->T_ / 2);
    if (i % 2 == 0)
      this->kernel_->applyOddEven(y + i * n, z);
    else
      this->kernel_->applyEvenOdd(y + i * n, z);
    applyGamma5<<<dimGrid,dimBlock>>>(y + i * n, y + i * n, this->L_, this->T_ / 2);

    if (i == 0) {
      assignDev<<<dimGrid,dimBlock>>>(x0, xi, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x + n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);

      applyPminus<<<dimGrid,dimBlock>>>(z, x + n * (this->Ls_ - 1), this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else if (i == this->Ls_ - 1) {
      applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPplus<<<dimGrid,dimBlock>>>(z, x0, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, this->mass_, n);
    }
    else {
      applyPplus<<<dimGrid,dimBlock>>>(z, x + (i + 1) * n, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
      applyPminus<<<dimGrid,dimBlock>>>(z, xim1, this->L_, this->T_ / 2);
      saxpyDev<<<dimGrid,dimBlock>>>(y + i * n, z, -1.0, n);
    }
    
    assignDev<<<dimGrid, dimBlock>>>(xim1, xi, n);
  }

  cudaFree(z);
  cudaFree(x0);
  cudaFree(xi);
  cudaFree(xim1);
}



void CudaDWF::applyPreconditionedHermitian(Complex* y, const Complex* x) const
{
  this->applyPreconditioned(y, x);
  this->makeHermitian(y, y);
}
