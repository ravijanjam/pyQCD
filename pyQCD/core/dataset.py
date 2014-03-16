import os
import cPickle
import zipfile
import warnings

import numpy as np
import numpy.random as npr

class DataSet:
    """Data set container holding data of the specified type.
    
    Once a data set has been initialized and contains at least one data
    point, it is then possible to call the jackknife or bootstrap member
    functions, supplying a measurement function, in order to compute an
    observable and estimate the error.
    
    The data is stored on disk in a zip file. Each file within the zip file
    corresponds to one of the measurement objects within the data set. If
    the type specified in the DataSet constructor inherits from the
    pyQCD.Object class, then the files within the data set zip file will be
    numpy zip archives. Otherwise, the data will be stored as ascii text
    in a file. The datatype for the data set is pickled and stored in a
    file name datatype.
    
    A DataSet object can be iteratred over or indexed in much the same way
    as a list.
    
    Attributes:
      bootstraps_cached (bool): Indicates whether copies of the
        bootstrapped data have been cached on disk.
      datatype (type): The python data type stored in the data set
      filename (str): The zip file name to save the data ot
      jackknifes_cached (bool): Indicates whether copies of the
        jackknifed data have been cached on disk.
      large_file (bool): Indicates whether 64 bit zip extensions
        have been used to compress a large file (over 2GB)
      num_data (int): The number of data stored in the data set
      storage_mode (int): Determines whether the zip file on disk
        is compressed or not.
    
    Args:
      datatype (type): The data type stored in the data set
      filename (str): The zip file to save the data to
      compress (bool, optional): Determines whether  compression is used
      
    Returns:
      DataSet: The data set object
      
    Examples:
      Create a data set to contain some gauge field configurations
      
      >>> import pyQCD
      >>> data = pyQCD.DataSet(pyQCD.Config, "myensemble.zip")
    """
    
    def __init__(self, datatype, filename, compress=True):
        """Constructor for pyQCD.DataSet (see help(pyQCD.DataSet))"""
        
        storage_mode = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
        
        self.datatype = datatype
        self.num_data = 0
        self.filename = os.path.abspath(filename)
        self.jackknifes_cached = False
        self.bootstraps_cached = False
        self.cache = {}
        
        try:
            zfile = zipfile.ZipFile(filename, 'w', storage_mode, True)
            self.large_file = True
        except RuntimeError:
            warnings.warn("> 2GB data set not supported.", RuntimeWarning)
            storage_mode = zipfile.ZIP_STORED
            zfile = zipfile.ZipFile(filename, 'w', storage_mode, False)
            self.large_file = False
            
        self.storage_mode = storage_mode
        
        typefile = open("type", 'w')
        cPickle.dump(datatype, typefile)
        typefile.close()
        
        zfile.write("type")
        zfile.close()
        os.unlink("type")
        
        self.iteration = 0
    
    def add_datum(self, datum):
        """Adds a datum to the dataset
        
        Args:
          datum: The datum to add to the data set
          
        Raises:
          TypeError: Supplied data type does not match the required data type
          
        Examples:
          Create a DataSet object to hold field configurations, then retrieve
          the field configurations generated by a Lattice object and store
          them. (Lattice here defaults to 4^3 x 8 with Wilson gauge action and
          beta = 5.5.)
          
          >>> import pyQCD
          >>> lattice = pyQCD.Lattice()
          >>> lattice.thermalize(100)
          >>> data = pyQCD.DataSet(pyQCD.Config, "myensemble.zip")
          >>> for i in xrange(10):
          ...     lattice.next_config()
          ...     data.add_datum(lattice.get_config())
        """
        
        if type(datum) != self.datatype:
            raise TypeError("Supplied data type {} does not match the required "
                            "data type {}".format(type(datum), self.datatype))
        
        filename = "{}{}.npz".format(self.datatype.__name__, self.num_data)
        self._datum_save(filename, datum)
                
        with zipfile.ZipFile(self.filename, 'a', self.storage_mode,
                             self.large_file) as zfile:
            zfile.write(filename)
        
        os.unlink(filename)
        self.num_data += 1
    
    def get_datum(self, index):
        """Retrieves the specified datum from the zip archive
        
        Args:
          index (int): The index of the item to be retrieved
          
        Returns:
          The corresponding datum of type specified in the datatype member
          variable
          
        Examples:
          Load a data set containing two-point functions and retrieve the first
          item in the data set.
          
          >>> import pyQCD
          >>> data = pyQCD.DataSet.load("correlators.zip")
          >>> print(data.get_datum(0))
          Field Configuration Object
          --------------------------
          Spatial extent: 4
          Temportal extent: 8
          Gauge action: wilson
          Inverse coupling (beta): 5.5
          Mean link (u0): 1.0
          
          Note that square brackets also achieve the same effect, e.g.:
          
          >>> print(data[0])
          Field Configuration Object
          --------------------------
          Spatial extent: 4
          Temportal extent: 8
          Gauge action: wilson
          Inverse coupling (beta): 5.5
          Mean link (u0): 1.0
        """
        
        filename = "{}{}.npz".format(self.datatype.__name__, index)
        with zipfile.ZipFile(self.filename, 'r', self.storage_mode,
                             self.large_file) as zfile:
            zfile.extract(filename)
         
        output = self._datum_load(filename)
        os.unlink(filename)
        
        return output
    
    def set_datum(self, index, datum):
        """Sets the specified datum to the specified value.
        This function currently is not implemented due to limitations in the
        zipfile module (no overwriting of archive files).
        
        Args:
          index (int): The datum number to overwrite
          datum: The datum to overwrite with, of type specified in the datatype
            member variable
            
        Raises:
          NotImplementedError: This feature has not yet been implemented.
        """
        
        raise NotImplementedError("DataSet.set_datum not properly implemented")
        
    def apply_function(self, func, args):
        """Applies the specified function to each datum in the dataset before
        saving each new datum over the original. Since set_datum is not currently
        implemented, this function will fail.
        
        Args:
          func (function): The function to apply the data set members
          args (list): The function arguments
        """
        
        for i in xrange(self.num_data):
            datum = self.get_datum(i)
            new_datum = func(datum, *args)
            self.set_datum(i, new_datum)
    
    def measure(self, func, data=[], args=[]):
        """Performs a measurement on each item in the data set using the
        supplied function and returns the average of the measurements
        
        Args:
          func (function): The measurement function, which should accept an
            object of type specified in the datatype member variable as its
            first argument
          data (list): A list of data indices to average before applying the
            measurement function. If an empty list is supplied, all data are
            averaged.
          args (list): The remaining arguments required by the supplied
            function
            
        Returns:
          The result of applying func with the supplied args to the average of
          the specified data.
          
        Examples:
          Load a set of correlators and compute the effective mass for the
          averaged set of correlators. For more information on this effective
          mass function, please check the docstring for the function.
          
          >>> import pyQCD
          >>> data = pyQCD.DataSet.load("correlators.zip")
          >>> effmass = data.measure(pyQCD.TwoPoint.compute_effmass)
        """

        if data == []:
            data = range(self.num_data)
            
        datum_sum = self.get_datum(data[0])

        for i in data[1:]:
            datum_sum += self.get_datum(i)
                
        datum_sum /= len(data)
        measurement = func(datum_sum, *args)
        
        return measurement
    
    def statistics(self):
        """Computes and returns the mean and standard deviation of the data
        within the dataset
        
        Returns:
          tuple: Containing the mean and standard deviation of the data
          
          Within the tuple, there are two objects of type specified in the
          datatype member variable, the first containing the average of the
          data, the second the standard deviation of the data.
          
        Examples:
          Load a set of correlators and compute the statistics for the data
          
          >>> import pyQCD
          >>> correlator_data = pyQCD.DataSet.load("two-point-functions.zip")
          >>> correlator_avg, correlator_std = correlator_data.statistics()
        """
        
        data_sum = self.get_datum(0)
        
        for i in xrange(1, self.num_data):
            data_sum += self.get_datum(i)
            
        data_mean = data_sum / self.num_data
        
        data_std = (self.get_datum(0) - data_mean)**2
        
        for i in xrange(1, self.num_data):
            data_std += (self.get_datum(i) - data_mean)**2
                
        data_std /= self.num_data
        
        return data_mean, data_std**0.5
    
    def generate_bootstrap_cache(self, num_bootstraps, binsize=1):
        """Generates the bootstrapped data and stores it in the folder
        pyQCDcache. This will save time if multiple bootstrap measurements need
        to be performed on the same data.
        
        Args:
          num_bootstraps (int): The number of bootstraps to perform
          binsize (int, optional): The bin size to use when performing binning
          
        Examples:
          Load some correlators and generate a set of bootstraps, which are
          cached for later bootstrap measurements.
          
          >>> import pyQCD
          >>> data = pyQCD.DataSet.load("some-correlator-dataset.zip")
          >>> data.generate_bootstrap_cache(100)
          
          Different bin sizes could also be used. Caching different bin sizes
          will store the results in different files, so multiple bin sizes can
          be stored in the cache simultaneously for later use.:
          
          >>> data.generate_bootstrap_cache(100, 10)
        """
        
        if binsize < 1:
            raise ValueError("Supplied bin size {} is less than 1"
                             .format(binsize))
        
        num_bins = self.num_data / binsize
        if self.num_data % binsize > 0:
            num_bins += 1
            
        try:            
            for i in xrange(num_bootstraps):
            
                bins = npr.randint(num_bins, size = num_bins).tolist()
            
                new_datum = self._get_bin(binsize, bins[0])
                for b in bins[1:]:
                    new_datum += self._get_bin(binsize, b)
                
                new_datum /= len(bins)
            
                bootstrap_name = "{}_bootstrap_binsize{}_{}" \
                  .format(self.datatype.__name__, binsize, i)
                self.cache[bootstrap_name] = new_datum
            
        except MemoryError:
            if not os.path.isdir("pyQCDcache"):
                os.makedirs("pyQCDcache")
            
            for i in xrange(num_bootstraps):
            
                bins = npr.randint(num_bins, size = num_bins).tolist()
            
                new_datum = self._get_bin(binsize, bins[0])
                for b in bins[1:]:
                    new_datum += self._get_bin(binsize, b)
                
                new_datum /= len(bins)
            
                bootstrap_filename = "pyQCDcache/{}_bootstrap_binsize{}_{}.npz" \
                  .format(self.datatype.__name__, binsize, i)
                self._datum_save(bootstrap_filename, new_datum)
            
        self.bootstraps_cached = True
    
    def bootstrap(self, func, num_bootstraps, binsize=1, args=[], use_cache=True):
        """Performs a bootstraped measurement on the dataset using the
        supplied function
        
        Args:
          func (function): The measurement function. The first argument of this
            function should accept a type specified in the DataSet datatype
            member variable.
          num_bootstraps (int): The number of bootstraps to perform.
          binsize (int, optional): The bin size to bin the data with before
            performing the bootstrap.
          args (list, optional): The additional arguments required by the
            supplied function
          use_cache (bool, optional): Determines whether to use any cached
            bootstrap data. If no cached data exists, it is created.
            
        Returns:
          tuple: The bootstrapped central value and standard deviation.
          
          The types within the tuple correspond to the types returned by the
          supplied measurement function.
            
        Examples:
          Load some correlators and bootstrap the effective mass curve.
          
          >>> import pyQCD
          >>> data = pyQCD.DataSet.load("correlators.zip")
          >>> effmass = data.bootstrap(pyQCD.TwoPoint.compute_effmass, 100)
        """
        
        if binsize < 1:
            raise ValueError("Supplied bin size {} is less than 1"
                             .format(binsize))
        
        num_bins = self.num_data / binsize
        if self.num_data % binsize > 0:
            num_bins += 1
            
        out = []
            
        if use_cache:            
            if not self.bootstraps_cached:
                self.generate_bootstrap_cache(num_bootstraps, binsize)
            
            for i in xrange(num_bins):
                bootstrap_datum \
                  = self._get_bootstrap_cache_datum(binsize, i, num_bootstraps)
            
                measurement = func(bootstrap_datum, *args)
                if measurement != None:
                    out.append(measurement)
            
        else:        
            for i in xrange(num_bootstraps):
            
                bins = npr.randint(num_bins, size = num_bins).tolist()
            
                new_datum = self._get_bin(binsize, bins[0])
                for b in bins[1:]:
                    new_datum += self._get_bin(binsize, b)
                
                new_datum /= len(bins)
                measurement = func(new_datum, *args)
                if measurement != None:                
                    out.append(measurement)
            
        return DataSet._mean(out), DataSet._std(out)
    
    def jackknife_datum(self, index, binsize=1):
        """Computes a jackknifed datum.
        
        Args:
          index (int): The index of the datum to remove from the dataset when
            performing the jackknife.
          binsize (int, optional): The bin size to use to bin the data before performing
            the jackknife.
            
        Returns:
          An object of type specified in the DataSet.datatype variable; the
          jackknifed datum.
          
        Raises:
          ValueError: Supplied index is greated than the number of data
          
        Examples:
          Load a set of correlators and compute the jackknifed datum
          corresponding the removal of the correlator for the first
          configuration.
          
          >>> import pyQCD
          >>> correlators = pyQCD.DataSet.load("some_configs.zip")
          >>> jackknife0 = correlators.jackknife_datum(0)
        """
        
        if binsize < 1:
            raise ValueError("Supplied bin size {} is less than 1"
                             .format(binsize))
        
        if index >= self.num_data:
            raise ValueError("Supplied index {} is greater than the number of "
                             "data {}"
                             .format(index, self.num_data))
        
        num_bins = self.num_data / binsize
        if self.num_data % binsize > 0:
            num_bins += 1
        
        data_sum = self._get_bin(binsize, 0)
        for i in xrange(1, num_bins):
            data_sum += self._get_bin(binsize, i)
            
        return (data_sum - self._get_bin(binsize, index)) / (num_bins - 1)
    
    def generate_jackknife_cache(self, binsize=1):
        """Generates the jackknifed data and stores it in the folder pyQCDcache
        
        Args:
          binsize (int, optional): The bin size to bin the data with before performing
            the jackknife
            
        Examples:
          Load some correlators and generate the jackknife cache for them. As
          with the bootstrap cache generation, different bin sizes can be
          cached simultaneously.
          
          >>> import pyQCD
          >>> correlators = pyQCD.DataSet.load("correlators.zip")
          >>> correlators.generate_jackknife_cache()
        """
        
        if binsize < 1:
            raise ValueError("Supplied bin size {} is less than 1"
                             .format(binsize))
        
        num_bins = self.num_data / binsize
        if self.num_data % binsize > 0:
            num_bins += 1
        
        try:
            data_sum = self._get_bin(binsize, 0)
            for i in xrange(1, num_bins):
                data_sum += self._get_bin(binsize, i)
        
            for i in xrange(num_bins):            
                bins = [j for j in xrange(num_bins) if j != i]
                
                new_datum \
                  = (data_sum - self._get_bin(binsize, i)) / (num_bins - 1)
            
                jackknife_name = "{}_jackknife_binsize{}_{}" \
                  .format(self.datatype.__name__, binsize, i)
            
                self.cache[jackknife_name] = new_datum
            
        except MemoryError:
            if not os.path.isdir("pyQCDcache"):
                os.makedirs("pyQCDcache")
            
            data_sum = self._get_bin(binsize, 0)
            for i in xrange(1, num_bins):
                data_sum += self._get_bin(binsize, i)
        
            for i in xrange(num_bins):            
                bins = [j for j in xrange(num_bins) if j != i]
            
                new_datum \
                  = (data_sum - self._get_bin(binsize, i)) / (num_bins - 1)
            
                jackknife_filename = "pyQCDcache/{}_jackknife_binsize{}_{}.npz" \
                  .format(self.datatype.__name__, binsize, i)
            
                self._datum_save(jackknife_filename, new_datum)
                    
        self.jackknifes_cached = True
    
    def jackknife(self, func, binsize=1, args=[], use_cache=True):
        """Performs a jackknifed measurement on the dataset using the
        supplied function.
        
        Args:
          func (function): The measurement function. The first argument of this
            function should accept a type specified in the DataSet datatype
            member variable.
          binsize (int, optional): The bin size to bin the data with before
            performing the jackknife.
          args (list, optional): The additional arguments required by the
            supplied function
          use_cache (bool, optional): Determines whether to use any cached
            jackknife data. If no cached data exists, it is created.
            
        Returns:
          tuple: The jackknifed central value and standard deviation.
          
          The types within the tuple correspond to the types returned by the
          supplied measurement function.
            
        Examples:
          Load some correlators and jackknife the effective mass curve.
          
          >>> import pyQCD
          >>> data = pyQCD.DataSet.load("correlators.zip")
          >>> effmass = data.jackknife(pyQCD.TwoPoint.compute_effmass)
        """
        
        if binsize < 1:
            raise ValueError("Supplied bin size {} is less than 1"
                             .format(binsize))
        
        num_bins = self.num_data / binsize
        if self.num_data % binsize > 0:
            num_bins += 1
            
        out = []
            
        if use_cache:            
            if not self.jackknifes_cached:
                self.generate_jackknife_cache(binsize)
            
            for i in xrange(num_bins):
                
                jackknife_datum \
                  = self._get_jackknife_cache_datum(binsize, i)
            
                measurement = func(jackknife_datum, *args)
                if measurement != None:
                    out.append(measurement)
            
        else:
        
            data_sum = self._get_bin(binsize, 0)
            for i in xrange(1, num_bins):
                data_sum += self._get_bin(binsize, i)
        
            for i in xrange(num_bins):            
                bins = [j for j in xrange(num_bins) if j != i]
            
                new_datum \
                  = (data_sum - self._get_bin(binsize, i)) / (num_bins - 1)
            
                measurement = func(new_datum, *args)
                if measurement != None:
                    out.append(measurement)
            
        return DataSet._mean(out), DataSet._std_jackknife(out)
    
    @classmethod
    def load(self, filename):
        """Load an existing data set from the supplied zip archive
        
        Args:
          filename (str): The containing the dataset
          
        Returns:
          DataSet: The data set stored in the specified file.
          
        Examples:
          Load a gauge ensemble:
          
          >>> import pyQCD
          >>> ensemble = pyQCD.DataSet.load("some_ensemble.zip")
        """
        
        storage_mode = zipfile.ZIP_DEFLATED
        compress = True
        
        try:
            zfile = zipfile.ZipFile(filename, 'r', storage_mode, True)
        except RuntimeError:
            storage_mode = zipfile.ZIP_STORED
            zfile = zipfile.ZipFile(filename, 'r', storage_mode, False)
            compress = False
        
        zfile.extract("type")
        
        typefile = open("type", 'r')
        datatype = cPickle.load(typefile)
        typefile.close()
        os.unlink("type")
        
        out = DataSet(datatype, "000.zip", compress)
        out.filename = os.path.abspath(filename)
        os.unlink("000.zip")
        
        data = [int(fname[len(datatype.__name__):-4])
                for fname in zfile.namelist()
                if fname.startswith(datatype.__name__) and fname.find("jackknife") < 0]
        
        if len(data) > 0:
            out.num_data = max(data) + 1
        
        return out
    
    def _get_bin(self, binsize, binnum):
        """Average the binsize data in binnum"""
        
        out = self.get_datum(binsize * binnum)
        
        first_datum = binsize * binnum + 1
        last_datum = binsize * (binnum + 1)
        
        if last_datum > self.num_data:
            last_datum = self.num_data
        
        for i in xrange(first_datum, last_datum):
            out += self.get_datum(i)
            
        return out / binsize

    @staticmethod
    def _add_measurements(a, b):
        """Adds two measurements (used for dictionaries etc)"""
        
        if type(a) == tuple:
            a = list(a)
        if type(b) == tuple:
            b = list(b)
        
        if hasattr(a, "__add__") and hasattr(b, "__add__") \
          and type(a) != list and type(b) != list:
            return a.__add__(b)
        
        if type(a) == list and type(b) == list:
            return [DataSet._add_measurements(x, y) for x, y in zip(a, b)]
        elif type(a) == dict and type(b) == dict:
            return DataSet._add_measurements(a, b.values())
        elif type(a) == dict and type(b) == list:
            return dict(zip(a.keys(), DataSet._add_measurements(a.values(), b)))
        elif type(a) == list and type(b) == dict:
            return DataSet._add_measurements(b, a)
        elif (type(a) == int or type(a) == float or type(a) == np.float64 \
          or type(a) == np.ndarray) \
          and (type(b) == int or type(b) == float or type(b) == np.float64 \
          or type(b) == np.ndarray):
            return a + b
        else:
            raise TypeError("Supplied types {} and {} cannot be summed"
                            .format(type(a), type(b)))

    @staticmethod
    def _sub_measurements(a, b):
        """Adds two measurements (used for dictionaries etc)"""
        
        if hasattr(a, "__sub__") and hasattr(b, "__sub__"):
            return a.__sub__(b)
        
        if type(a) == tuple:
            a = list(a)
        if type(b) == tuple:
            b = list(b)
        
        if type(a) == list and type(b) == list:
            return [DataSet._sub_measurements(x, y) for x, y in zip(a, b)]
        elif type(a) == dict and type(b) == dict:
            return DataSet._sub_measurements(a, b.values())
        elif type(a) == dict and type(b) == list:
            return dict(zip(a.keys(), DataSet._sub_measurements(a.values(), b)))
        elif type(a) == list and type(b) == dict:
            return dict(zip(b.keys(), DataSet._sub_measurements(a, b.values())))
        elif (type(a) == int or type(a) == float or type(a) == np.float64 \
          or type(a) == np.ndarray) \
          and (type(b) == int or type(b) == float or type(b) == np.float64 \
          or type(b) == np.ndarray):
            return a - b
        else:
            raise TypeError("Supplied types {} and {} cannot be summed"
                            .format(type(a), type(b)))

    @staticmethod
    def _mul_measurements(a, b):
        """Adds two measurements (used for dictionaries etc)"""
        
        if type(a) == tuple:
            a = list(a)
        if type(b) == tuple:
            b = list(b)
        
        if hasattr(a, "__mul__") and hasattr(b, "__mul__") \
          and type(a) != list and type(b) != list:
            return a.__mul__(b)
        
        if type(a) == list and type(b) == list:
            return [DataSet._mul_measurements(x, y) for x, y in zip(a, b)]
        elif type(a) == dict and type(b) == dict:
            return DataSet._mul_measurements(a, b.values())
        elif type(a) == dict and type(b) == list:
            return dict(zip(a.keys(), DataSet._mul_measurements(a.values(), b)))
        elif type(a) == list and type(b) == dict:
            return DataSet._mul_measurements(b, a)
        elif (type(a) == int or type(a) == float or type(a) == np.float64 \
          or type(a) == np.ndarray) \
          and (type(b) == int or type(b) == float or type(b) == np.float64 \
          or type(b) == np.ndarray):
            return a * b
        else:
            raise TypeError("Supplied types {} and {} cannot be summed"
                            .format(type(a), type(b)))
            
    @staticmethod
    def _div_measurements(a, div):
        """Divides a measurement by a scalar value"""
        
        if type(div) != float and type(div) != int:
            raise TypeError("Unsupported divisor of type {}".format(type(div)))
        
        if hasattr(a, "__div__"):
            return a.__div__(div)
        
        if type(a) == list or type(a) == tuple:
            return [DataSet._div_measurements(x, div) for x in a]
        
        if type(a) == dict:
            return dict(zip(a.keys(), DataSet._div_measurements(a.values(),
                                                                div)))
        
        if type(a) == float or type(a) == int or type(a) == np.float64 \
          or type(a) == np.ndarray:
            return a / div
            
    @staticmethod
    def _sqrt_measurements(a):
        """Divides a measurement by a scalar value"""
        
        if type(a) == list or type(a) == tuple:
            return [DataSet._sqrt_measurements(x) for x in a]
        
        if type(a) == dict:
            return dict(zip(a.keys(), DataSet._sqrt_measurements(a.values())))
        
        if type(a) == float or type(a) == int or type(a) == np.float64 \
          or type(a) == np.ndarray:
            return np.sqrt(a)
        
    @staticmethod
    def _mean(data):
        """Calculates the mean of the supplied list of measurements"""
        
        if type(data) == list:
            out = data[0]
            
            for datum in data[1:]:
                out = DataSet._add_measurements(out, datum)
                
            out = DataSet._div_measurements(out, len(data))
            
            return out
        
        if type(data) == np.ndarray:
            return np.mean(data, axis=0)

    @staticmethod
    def _std(data):
        """Calculates the standard deviation of the supplied list of
        measurements"""
        
        if type(data) == list:
            mean = DataSet._mean(data)
            
            diff = DataSet._sub_measurements(data[0], mean)
            out = DataSet._mul_measurements(diff, diff)
            
            for datum in data[1:]:
                diff = DataSet._sub_measurements(datum, mean)
                square = DataSet._mul_measurements(diff, diff)
                out = DataSet._add_measurements(out, square)
                
            return DataSet._sqrt_measurements(DataSet \
                                              ._div_measurements(out, len(data)))
        
        if type(data) == np.ndarray:
            return np.std(data, axis=0)

    @staticmethod
    def _std_jackknife(data):
        """Calculates the standard deviation of the supplied list of
        measurements for the case of the jackknife"""
        
        if type(data) == list:
            mean = DataSet._mean(data)
            
            diff = DataSet._sub_measurements(data[0], mean)
            out = DataSet._mul_measurements(diff, diff)
            
            for datum in data[1:]:
                diff = DataSet._sub_measurements(datum, mean)
                square = DataSet._mul_measurements(diff, diff)
                out = DataSet._add_measurements(out, square)
                
            div = float(len(data)) / (len(data) - 1)
                
            return DataSet._sqrt_measurements(DataSet._div_measurements(out, div))
        
        if type(data) == np.ndarray:
            return np.sqrt(data.shape[0] - 1) * np.std(data, axis=0)
        
    @staticmethod
    def _datum_save(filename, datum):
        """Saves the file either in plain text or numpy zip archive depending
        on the format"""
        
        try:
            datum.save(filename)
        except AttributeError:
            with open(filenaem) as f:
                f.write(datum.__repr__())
                
    def _datum_load(self, filename):
        """Loads the datum from disk into the appropriate type"""
        
        try:
            return self.datatype.load(filename)
        except AttributeError:
            from numpy import array
            with open(filename) as f:
                return self.datatype(eval(f.read()))
            
    def _get_bootstrap_cache_datum(self, binsize, index, num_bootstraps):
        """Loads a cached jackknife or bootstrap datum"""
        
        datum_name = "{}_bootstrap_binsize{}_{}".format(self.datatype.__name__,
                                                        binsize, index)
        
        try:
            return self.cache[datum_name]
        except KeyError:
            try:
                return self._datum_load("pyQCDcache/{}.npz".format(datum_name))
            except IOError:
                self.generate_bootstrap_cache(num_bootstraps, binsize)
                return self._get_bootstrap_cache_datum(binsize, index,
                                                       num_bootstraps)
            
    def _get_jackknife_cache_datum(self, binsize, index):
        """Loads a cached jackknife or jackknife datum"""
        
        datum_name = "{}_jackknife_binsize{}_{}".format(self.datatype.__name__,
                                                        binsize, index)
        
        try:
            return self.cache[datum_name]
        except KeyError:
            try:
                return self._datum_load("pyQCDcache/{}.npz".format(datum_name))
            except IOError:
                self.generate_jackknife_cache(binsize)
                return self._get_jackknife_cache_datum(binsize, index)

    def __getitem__(self, index):
        """Square brackets overload"""
        return self.get_datum(index)
    
    def __iter__(self):
        """Make this object iterable"""
        return self
    
    def next(self):
        """Return the appropriate datum"""
        
        if self.iteration >= self.num_data:
            raise StopIteration
        else:
            self.iteration += 1
            return self[self.iteration - 1]
    
    def __str__(self):
        
        out = \
          "Data Set Object\n" \
          "---------------\n" \
          "Data type: {}\n" \
          "Data file: {}\n" \
          "Number of data: {}".format(self.datatype.__name__,
                                      self.filename, self.num_data)
        
        return out
