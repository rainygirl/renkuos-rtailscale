# Build on RenkuOS itself: make && make install
NAME      = RTailscale
CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wno-multichar -Wno-unused-parameter
LIBS      = -lbe -lnetwork
SOURCES   = $(wildcard src/*.cpp)
OBJECTS   = $(SOURCES:.cpp=.o)
APPS      = $(HOME)/config/non-packaged/apps

$(NAME): $(OBJECTS) RTailscale.rdef
	$(CXX) -o $@ $(OBJECTS) $(LIBS)
	rc -o $(NAME).rsrc RTailscale.rdef
	xres -o $@ $(NAME).rsrc
	mimeset -f $@

src/%.o: src/%.cpp $(wildcard src/*.h)
	$(CXX) $(CXXFLAGS) -c $< -o $@

install: $(NAME)
	mkdir -p $(APPS)
	cp $(NAME) $(APPS)/$(NAME)
	mimeset -f $(APPS)/$(NAME)

clean:
	rm -f $(NAME) $(NAME).rsrc src/*.o

.PHONY: install clean
